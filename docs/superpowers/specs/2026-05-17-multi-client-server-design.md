# Design: Multi-client Ruby TCP server

- **Date**: 2026-05-17
- **Status**: Draft — awaiting user review
- **Branch**: `feature/multi-client-server` (forked from
  `feature/viewport-screenshot-and-prompt` at `3111ad6`; bundles a
  protocol-level breaking change — one-time version handshake — so
  this work targets the **next** release after 0.1.0, not a patch to it).
- **Author**: Alexander V. Zinin (with Claude Code)

## 1. Context

`su_mcp/su_mcp/core/server.rb` today maintains a **single `@client`
slot**: `accept_one_client` is called only when `@client.nil?`. A second
concurrent TCP connection sits in the kernel backlog with no app-side
`accept`, so the second Python process sees a 60-second `recv` timeout
rather than `ECONNREFUSED` — confusing failure mode, and impossible to
work around without restarting the SketchUp plugin or detaching the
first client from Claude Code's MCP config (documented as a known
limitation in `CLAUDE.md`).

This blocks two real workflows:

- Running `examples/smoke_check.py` against a SketchUp instance that is
  already serving a Claude Code session.
- Running **two Claude Code sessions in parallel** against the same
  SketchUp instance — second session silently hangs on every tool call.

The fix is to make `core/server.rb` accept and service N concurrent TCP
clients while preserving the single-threaded execution model that
SketchUp's Ruby API mandates (no native threads, all I/O on the UI
thread via `UI.start_timer`).

A second, orthogonal-but-bundled cleanup ships in the same branch
because the codebase is small, the user is its sole consumer, and the
breaking-protocol change is best amortised over a single release:

- **One-time version handshake on connect.** Today every request
  carries `client_version` and every response carries `server_version`;
  with multi-client, the connection is a natural place to do the check
  once, freeing the per-request envelope from version overhead.

## 2. Goals

- **Multi-client capacity.** N concurrent TCP clients connected
  simultaneously; each sees a regular JSON-RPC stream with no awareness
  that other clients exist.
- **Serial execution preserved.** Operations are dispatched one at a
  time on the SketchUp UI thread. No concurrency of handler bodies
  introduced.
- **Global FIFO scheduling.** Frames are processed in the order they
  fully decode into the server's queue — single shared queue, not per
  client.
- **Per-client isolation of failure.** A frame from client A that
  triggers a parse error, write timeout, version-mismatch, or handler
  exception affects only A. Other clients keep working uninterrupted.
- **One-time version handshake.** `hello` is the mandatory first JSON-RPC
  method on each connection. After it succeeds, regular `tools/call`
  requests carry no `client_version` field and responses carry no
  `server_version` field.
- **Tests for both axes.** Ruby unit tests cover the multi-client
  scheduling, error isolation, and handshake semantics. A live smoke
  script verifies end-to-end behavior with two real Python processes
  against a running SketchUp.

## 3. Non-goals

- **No session locks, no per-entity locks, no MVCC.** Logical races
  between clients (one moves an entity, another deletes it) are the
  user's organisational responsibility. Rationale: the user can already
  break this invariant manually (mouse-click delete between two MCP
  tool-calls in a single LLM session); two clients interleaving on the
  same model is a workflow choice, not a server problem.
- **No client authentication.** Network-level trust only — same model as
  today; the `0.0.0.0` configuration documented in `CLAUDE.md` already
  states "trust your network".
- **No hard cap on concurrent clients.** OS file-descriptor limits are
  the only ceiling. Adding a cap would force a "what does the (N+1)th
  client see?" design and tests for no real benefit on a single-user
  desktop tool.
- **No round-robin reads** (interleaved byte-level reads to approximate
  TCP arrival order across clients). The user has explicitly chosen
  "FIFO by decoded-frame arrival" over fair round-robin scheduling.
- **No per-tick processing cap.** Matches today's behaviour (all queued
  frames processed in a single tick, bounded only by per-client read
  iterations). Pipelining floods cause the same temporary UI freeze as
  today.
- **No backward compatibility.** The handshake is a breaking wire-level
  change. Sole user has no deployed clients to upgrade.
- **No idle deadline.** The current `IDLE_DEADLINE_S = 300` is removed
  entirely. Half-open sockets are caught either by next-write failure or
  OS `SO_KEEPALIVE` (enabled on every accepted socket).
- **No changes to handler implementations.** Geometry, materials,
  booleans, joinery, export, model introspection, viewport screenshot —
  all unchanged. The work is purely in `core/server.rb`,
  `handlers/dispatch.rb`, `core/compat.rb`, the Python
  `connection.py`, and tests/docs.

## 4. High-level structure of changes

```
su_mcp/su_mcp/
  core/server.rb          MAJOR REWRITE — @clients hash, ClientState,
                          global @frame_queue, accept/drain/dispatch
                          phases, per-client isolation, SO_KEEPALIVE,
                          handshake gate.
  core/client_state.rb    NEW — per-client state struct (id, sock,
                          reader, label, handshaked, client_version).
  core/compat.rb          MINOR — no logic change; check called from
                          new handshake site instead of per-request.
  handlers/dispatch.rb    MODIFY — remove per-request version check
                          and get_version bypass, remove dormant
                          prompts/list / resources/list branches.
                          (Handlers do NOT receive ClientState; per-handler
                          logs stay context-free — see §8.4.)

src/sketchup_mcp/
  connection.py           MAJOR MODIFY — _handshake() on connect,
                          drop client_version from per-request body,
                          drop server_version from response check
                          (handshake covers it), drop get_version
                          bypass.
  compat.py               MINOR — error message wording adjusted
                          (no more "send every request" framing).
  errors.py               UNCHANGED.
  tools.py                UNCHANGED (get_version stays as a regular
                          tool that returns the server version
                          report, just no longer carries diagnostic
                          bypass semantics).

examples/
  smoke_multi_client.py   NEW — spawns 2 subprocess.Popen Python
                          processes that exercise the server in
                          parallel; asserts neither starves.

test/
  test_server_multi_client.rb  NEW — fake-socket multi-client cases.
  test_server_compat.rb        REWRITE — handshake-flow scenarios.

tests/
  test_connection.py      MODIFY — handshake roundtrip, retry-after-
                          stale-socket re-handshakes, drop
                          client_version assertions.

CLAUDE.md                 REWRITE several sections (see §11).
docs/release.md           Append breaking-protocol note for the
                          upcoming release.
```

## 5. Architecture

### 5.1 ClientState

Per-connection record:

```ruby
module SU_MCP
  module Core
    class ClientState
      attr_reader   :id, :sock, :reader, :label
      attr_accessor :handshaked, :client_version, :close_after_response

      def initialize(id, sock)
        @id                   = id
        @sock                 = sock
        @reader               = Framing::FrameReader.new
        @label                = "##{id}[#{peer_label(sock)}]"
        @handshaked           = false
        @client_version       = nil
        @close_after_response = false
      end

      def closed?
        @sock.closed?
      end

      private

      def peer_label(sock)
        peer = sock.peeraddr
        "#{peer[2]}:#{peer[1]}"
      rescue StandardError
        "unknown"
      end
    end
  end
end
```

No `last_progress_at` — idle-deadline removed entirely. No pending-write
buffer — writes are still synchronous (with `IO.select` write probe).

### 5.2 Server fields

```ruby
class Server
  TIMER_INTERVAL          = 0.1     # seconds between ticks (unchanged)
  READ_CHUNK              = 64 * 1024
  READ_MAX_ITERATIONS     = 50      # per client per tick
  WRITE_SELECT_TIMEOUT_S  = 1.0     # write probe (unchanged)
  # IDLE_DEADLINE_S removed.

  def initialize
    @server         = nil
    @clients        = {}      # sock => ClientState
    @frame_queue    = []      # [[ClientState, body_bytes], ...]
    @next_client_id = 0
    @running        = false
    @timer_id       = nil
    @processing     = false   # single shared reentrance guard
  end
end
```

Single shared `@processing` because handler execution is single-threaded
anyway. No reason to mint per-client guards.

### 5.3 Tick algorithm

```ruby
def on_timer_tick
  return unless @running
  return if @processing
  @processing = true
  begin
    accept_pending_clients
    drain_reads_all_clients   # FrameReader per client → @frame_queue
    process_frame_queue       # FIFO dispatch
  rescue StandardError => e
    # Server-level error — log, do NOT reset clients.
    Logger.log_error("server.timer", e)
  ensure
    @processing = false
  end
end
```

#### accept_pending_clients

```ruby
ACCEPT_ABORTED_MAX = 10   # defensive cap on ECONNABORTED churn per tick

def accept_pending_clients
  aborted = 0
  loop do
    begin
      sock = @server.accept_nonblock
    rescue IO::WaitReadable
      return
    rescue Errno::ECONNABORTED
      aborted += 1
      # Windows kernel can keep yielding ECONNABORTED for aborted
      # connections sitting in the backlog. Cap the retries so a
      # pathological backlog cannot wedge the UI timer.
      return if aborted >= ACCEPT_ABORTED_MAX
      next
    end
    begin
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
    rescue StandardError => e
      # accept succeeded but the socket is unusable. Close it; do NOT
      # register — registered-or-closed is the invariant we maintain.
      begin
        sock.close
      rescue StandardError
        # best-effort
      end
      Logger.log_error("server.accept_setsockopt", e)
      next
    end
    state = ClientState.new(@next_client_id, sock)
    @next_client_id += 1
    @clients[sock] = state
    Logger.log_tool("server", "client_connected", client_label: state.label)
  end
end
```

`SO_KEEPALIVE` enabled per socket — OS-level half-open detection
(~2 hours Linux/Windows default). Drains the entire kernel backlog in
one tick, with `ACCEPT_ABORTED_MAX` as a defensive ceiling against a
runaway `ECONNABORTED` loop on Windows.

#### drain_reads_all_clients

```ruby
def drain_reads_all_clients
  # snapshot — clients may be removed mid-iteration on errors
  @clients.values.each do |state|
    drain_one_client(state)
  end
end

def drain_one_client(state)
  return if state.closed?
  iterations = 0
  loop do
    return if iterations >= READ_MAX_ITERATIONS
    chunk = state.sock.read_nonblock(READ_CHUNK)
    state.reader.feed(chunk).each do |body|
      @frame_queue << [state, body]
    end
    iterations += 1
  end
rescue IO::WaitReadable
  # kernel buffer drained; move on
rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
  close_client(state, "client_disconnected")
rescue Core::StructuredError => e
  # framing error (zero-length / oversize) — stream desynced.
  send_transport_error(state, e, nil)
  close_client(state, "framing_error: #{e.message}")
end
```

Read iterations are bounded per client (50 chunks × 64 KB = 3.2 MB).
With N clients that means up to N × 3.2 MB drained per tick — acceptable
on desktop hardware.

Frames decoded *before* an error in the same chunk **do** make it into
`@frame_queue`; `process_frame_queue` will skip them later because
`state.closed?` becomes true.

#### process_frame_queue

```ruby
def process_frame_queue
  until @frame_queue.empty?
    state, body = @frame_queue.shift
    next if state.closed?            # client died between drain and dispatch

    response = handle_frame(state, body)
    next if response.nil?            # JSON-RPC notification
    write_response(state, response)
  end
end

def handle_frame(state, body)
  request = JSON.parse(body)
  is_notification = request.is_a?(Hash) && !request.key?("id")

  if !state.handshaked
    if is_notification
      # JSON-RPC §4.1: notifications never receive a response. Pre-handshake
      # notifications are a protocol violation; close silently.
      close_client(state, "pre_handshake_notification")
      return nil
    end
    handle_pre_handshake(state, request)   # always has an id at this point
  else
    Handlers::Dispatch.handle(request)     # may return nil for post-handshake notifications
  end
rescue JSON::ParserError => e
  Logger.log_error("server.parse", e, client_label: state.label)
  # JSON-RPC §5.1: parse errors are reported with id=null even if the
  # malformed body might have been a notification (we can't tell).
  send_transport_error(state, Core::StructuredError.new(-32700,
    "parse error: #{e.message}"), nil)
  close_client(state, "parse_error")
  nil
rescue StandardError => e
  # defensive — Dispatch should have wrapped, but never trust.
  Logger.log_error("server.handler", e, client_label: state.label)
  rid = request.is_a?(Hash) ? request["id"] : nil
  Core::Errors.build_error_response(-32603, e.message,
    Core::Errors.exception_to_data(e, "?", {}), rid)
end
```

#### handle_pre_handshake

```ruby
def handle_pre_handshake(state, request)
  unless request.is_a?(Hash) && request["jsonrpc"] == "2.0"
    return reject_handshake(state, request,
      Core::StructuredError.new(-32600, "invalid envelope (pre-handshake)"))
  end
  method = request["method"]

  unless method == "hello"
    return reject_handshake(state, request,
      Core::StructuredError.new(-32600,
        "first method must be 'hello' (got: #{method.inspect})"))
  end

  params = request["params"]
  unless params.is_a?(Hash) && params["client_version"].is_a?(String)
    return reject_handshake(state, request,
      Core::StructuredError.new(-32602,
        "hello requires params.client_version (string)"))
  end

  begin
    Core::Compat.check_python_version(params["client_version"])
  rescue Core::StructuredError => e
    return reject_handshake(state, request, e)
  end

  state.handshaked     = true
  state.client_version = params["client_version"]
  Logger.log_tool("server", "handshake_ok",
    "client_version=#{state.client_version}",
    client_label: state.label)

  # Build a raw JSON-RPC envelope directly — NOT via
  # Handlers::Dispatch.build_success_response, because that wrapper
  # turns `result` into the MCP `tools/call` shape
  # `{content:[{type:text,text:...}], isError:false}`. The handshake
  # response carries `server_version` and `client_id` as a plain
  # JSON-RPC `result` object so the Python client can read them
  # directly.
  {
    "jsonrpc" => "2.0",
    "result"  => {
      "server_version" => Core::Compat::SERVER_VERSION,
      "client_id"      => state.id,
    },
    "id"      => request["id"],
  }
end

def reject_handshake(state, request, structured_error)
  rid = request.is_a?(Hash) ? request["id"] : nil
  state.close_after_response = true
  Core::Errors.build_error_response(structured_error.code,
    structured_error.message,
    Core::Errors.exception_to_data(structured_error, "hello", {}), rid)
end
```

`process_frame_queue` honours `@close_after_response` after writing:

```ruby
def write_response(state, response)
  body  = encode_response_body(response)
  frame =
    begin
      Framing.encode_frame(body)
    rescue Core::StructuredError => e
      # Body exceeds the 64 MiB framing cap (or is unexpectedly empty).
      # We owe the caller *something* — try a small fallback envelope.
      # If even the fallback won't encode, give up and close the client
      # so the per-client failure isolation guarantee is honored.
      Logger.log_error("server.encode_frame", e, client_label: state.label)
      fallback = Errors.build_error_response(-32603,
        "response too large for transport",
        Errors.exception_to_data(e, "?", {}),
        response.is_a?(Hash) ? response["id"] : nil)
      begin
        Framing.encode_frame(JSON.generate(fallback))
      rescue StandardError
        close_client(state, "encode_frame_failed")
        return
      end
    end

  ready = IO.select(nil, [state.sock], nil, WRITE_SELECT_TIMEOUT_S)
  unless ready
    close_client(state, "write_timeout")
    return
  end
  state.sock.write(frame)
  state.sock.flush

  if state.close_after_response
    close_client(state, "handshake_rejected")
  end
rescue Errno::EPIPE, Errno::ECONNRESET, IOError
  close_client(state, "write_failed")
end
```

(The `close_after_response` flag is a regular `attr_accessor` on
`ClientState` — see §5.1 — and is read once after a successful
write. Only the handshake-rejection path sets it today.)

### 5.4 close_client

```ruby
def close_client(state, reason)
  # Idempotent: `@clients` membership is the source of truth for
  # "still tracked". Second call (e.g. drain_one_client after a
  # write_response rescue already removed the client) is a no-op.
  return unless @clients.key?(state.sock)
  @clients.delete(state.sock)
  begin
    state.sock.close unless state.closed?
  rescue StandardError
    # best-effort
  end
  Logger.log_tool("server", "client_disconnected",
    "reason=#{reason}",
    client_label: state.label)
end
```

Pending frames belonging to the now-closed client **are not removed from
`@frame_queue`**. They will be skipped by the `state.closed?` check at
the top of each iteration in `process_frame_queue`. This avoids an
O(queue) scan on every disconnect.

## 6. Protocol: one-time version handshake

### 6.1 Wire format

No new frame types. `hello` is a regular JSON-RPC method.

**Client → server (first frame after TCP connect):**
```json
{"jsonrpc":"2.0","method":"hello","params":{"client_version":"0.2.0"},"id":0}
```

**Server → client (success):**
```json
{"jsonrpc":"2.0","result":{"server_version":"0.2.0","client_id":3},"id":0}
```

**Server → client (version mismatch):**
```json
{"jsonrpc":"2.0","error":{"code":-32001,"message":"…","data":{…}},"id":0}
```
…followed by `close()` on the server-side socket.

**Server → client (other handshake violations):** `-32600` (envelope) or
`-32602` (missing `client_version`), followed by close.

### 6.2 Post-handshake protocol

After `state.handshaked = true`:

- Subsequent client requests are regular JSON-RPC, **without** the
  `client_version` field.
- Subsequent server responses are regular JSON-RPC, **without** the
  `server_version` field.
- `tools/call` works as today.
- `Handlers::Dispatch.handle` no longer calls
  `Core::Compat.check_python_version` — the check is gone from the
  per-request path entirely.
- The `is_get_version_call` bypass logic is removed from `dispatch.rb`.
  `get_version` becomes an ordinary `tools/call` target with no special
  semantics. (Python keeps it in `_RETRY_SAFE_TOOLS` because it is
  side-effect-free.)
- `resources/list` and `prompts/list` branches in `dispatch.rb` are
  removed; FastMCP never forwards them anyway, and the dormant
  fall-through has no operational purpose now that we're already
  touching this file.

### 6.3 Failure semantics

| Trigger | Server response | Server post-action |
|---|---|---|
| `hello` with compatible version | success + `server_version` + `client_id` | mark `handshaked = true` |
| `hello` with incompatible version | `-32001` error envelope | close socket |
| `hello` with malformed params | `-32602` | close socket |
| Non-`hello` request before handshake | `-32600` "first method must be 'hello'" | close socket |
| JSON parse error before handshake | `-32700` | close socket |
| Notification (no `id`) before handshake | (no response by JSON-RPC spec) | close socket — strict protocol violation |

### 6.4 Python client logic

Updated `connect()` performs the handshake before returning:

```python
async def connect(self) -> None:
    self._reader, self._writer = await asyncio.open_connection(
        self.host, self.port
    )
    try:
        # Bound the handshake so a Ruby that accepted TCP but hangs
        # before replying surfaces as a timeout instead of an
        # indefinite block on _recv_frame's readexactly().
        await asyncio.wait_for(self._handshake(), timeout=self.timeout)
    except asyncio.TimeoutError:
        await self.disconnect()
        raise SketchUpError(-32000,
            f"handshake timed out after {self.timeout}s") from None
    except Exception:
        await self.disconnect()
        raise

async def _handshake(self) -> None:
    request = {
        "jsonrpc": "2.0",
        "method": "hello",
        "params": {"client_version": compat.CLIENT_VERSION},
        "id": 0,
    }
    body = json.dumps(request).encode("utf-8")
    self._writer.write(struct.pack(">I", len(body)) + body)
    await self._writer.drain()
    response_body = await self._recv_frame()
    try:
        response = json.loads(response_body)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32700,
            f"handshake parse error: {e}") from e
    if not isinstance(response, dict):
        raise SketchUpError(-32603,
            f"malformed handshake response: {type(response).__name__}")
    if "error" in response:
        err = response["error"] if isinstance(response.get("error"), dict) else {}
        code = err.get("code", -32000)
        if code == -32001:
            raise IncompatibleVersionError(err.get("message", "version mismatch"))
        raise SketchUpError(code,
            err.get("message", "handshake failed"),
            err.get("data"))
    result = response.get("result") or {}
    if not isinstance(result, dict):
        raise SketchUpError(-32603,
            f"malformed handshake result: {type(result).__name__}")
    server_version = result.get("server_version")
    self._server_version = server_version
    self._client_id      = result.get("client_id")
    # belt-and-suspenders — server told us the version, but Python ranges
    # may differ from Ruby's view of "compatible". A second check here is
    # cheap and surfaces a mismatch immediately.
    compat.check_ruby_version(server_version)
```

`_send_once` simplifies:

```python
async def _send_once(self, name, args):
    if self._writer is None or self._writer.is_closing():
        await self._connect_or_raise()   # this now does handshake too
    rid = self._next_id
    self._next_id += 1
    request = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {"name": name, "arguments": args},
        "id": rid,
        # NB: no client_version
    }
    body = json.dumps(request).encode("utf-8")
    if len(body) > config.MAX_MESSAGE_SIZE:
        raise SketchUpError(-32600,
            f"request too large: {len(body)} bytes (cap {config.MAX_MESSAGE_SIZE})")
    try:
        response_body = await asyncio.wait_for(
            self._roundtrip(body), timeout=self.timeout)
    except ... (unchanged) ...
    # No server_version check — handshake covered it.
    if response.get("id") != rid: ...
    if "error" in response: ...
    return response.get("result", {})
```

The retry path for `_StaleSocketError` works naturally: a fresh socket
goes through `_handshake()` again before the retried request is sent.

### 6.5 Compat module wording

`compat.py` and `compat.rb` keep their existing ranges, regex parsing,
and `check_*_version` functions. Error messages drop the "every request
carries `client_version`/`server_version`" sentence (no longer true)
and instead say "handshake failed: …". `get_version` tool description
is updated to mention it is a runtime sanity probe rather than the
"only diagnostic bypass".

## 7. Per-client error isolation

Goals reiterated explicitly because this is the highest-risk surface:

| Error site | Today (single client) | After |
|---|---|---|
| Parse error on inbound frame | Reset @client | Close that client only; other clients keep running |
| Write timeout (1 s `IO.select`) | Reset @client | Close that client only |
| `EPIPE`/`ECONNRESET` on read | Reset @client | Close that client only |
| `EPIPE`/`ECONNRESET` on write | Reset @client | Close that client only |
| `Framing::FrameReader` `StructuredError` (zero-length / oversize) | Reset @client | Close that client only |
| Handler raises `Core::StructuredError` (e.g. `-32602` bad params) | Build `-32602` envelope, keep socket | Same — client stays connected; envelope written |
| Handler raises `StandardError` (defensive `-32603`) | Build `-32603` envelope, keep socket | Same — client stays |
| `JSON::GeneratorError` / `Encoding::UndefinedConversionError` while encoding response | Fallback envelope, keep socket | Same — client stays |
| Server-level error in `on_timer_tick` (above the per-client loop) | Reset @client | Log only; **no client reset** (no shared state to reset) |
| Idle (no frames for N seconds) | Reset @client at 300 s | Never (`IDLE_DEADLINE_S` removed). `SO_KEEPALIVE` catches truly dead peers. |

The structural invariant: every per-client failure path calls
`close_client(state, reason)` and continues. No path exists that closes
all clients at once.

## 8. Logging

### 8.1 Logger API extension

`Logger.log_tool` and `Logger.log_error` gain an **optional keyword
argument** `client_label:` (keyword, not positional — keeps every
existing positional callsite in `handlers/*` working unchanged):

```ruby
# core/logger.rb (after change)
def self.log_tool(tool, status, extra = nil, client_label: nil)
  body = "tool=#{tool} status=#{status}"
  body << " client=#{client_label}" if client_label
  body << " #{extra}" if extra
  log("INFO", body)
end

def self.log_error(tool, exception, client_label: nil)
  body = "tool=#{tool}"
  body << " client=#{client_label}" if client_label
  body << " class=#{exception.class.name} msg=#{exception.message}"
  log("ERROR", body)
  return unless Config.log_level == "DEBUG" && exception.backtrace
  exception.backtrace.first(3).each { |bt| write("    #{bt}") }
end
```

### 8.2 Sample lines

```
[INFO ] tool=server status=client_connected client=#0[127.0.0.1:54321]
[INFO ] tool=server status=handshake_ok client=#0[127.0.0.1:54321] client_version=0.2.0
[INFO ] tool=create_component status=ok client=#0[127.0.0.1:54321] bbox_mm=…
[WARN ] tool=server status=client_disconnected client=#0[127.0.0.1:54321] reason=write_timeout
[INFO ] tool=server status=client_connected client=#1[192.168.20.10:51234]
[INFO ] tool=server status=handshake_ok client=#1[192.168.20.10:51234] client_version=0.2.0
```

The `client_id` is server-assigned, monotonically increasing, never
reused for the lifetime of the server process. Format `#N[host:port]`
chosen so logs are short in grep output while still allowing the
operator to correlate with the Python process by inspecting the ephemeral
port number.

### 8.3 Log lines without a client label

Two categories happen above any per-client context and therefore omit
the `client=` field:

- `server.timer` failures (top-level rescue in `on_timer_tick`).
- `server.accept` failures (before the `ClientState` exists).

These keep the existing `tool=server` prefix without a `client=` segment.

### 8.4 Per-handler logging

Handler-side log calls (`handlers/geometry.rb`, etc.) do not need to be
updated — they don't have access to `ClientState`. Per-tool log lines
will continue to look like `tool=create_component status=ok …` without
a client label, which is acceptable: the surrounding `server` log lines
on the same client (handshake_ok, client_disconnected) provide enough
context to correlate. Threading `ClientState` down into every handler is
explicitly out of scope.

## 9. Configuration & timing

No new configuration keys. All knobs are server-internal constants in
`core/server.rb`:

| Constant | Value | Notes |
|---|---|---|
| `TIMER_INTERVAL` | `0.1` | unchanged |
| `READ_CHUNK` | `64 * 1024` | unchanged |
| `READ_MAX_ITERATIONS` | `50` | per client per tick |
| `WRITE_SELECT_TIMEOUT_S` | `1.0` | unchanged |
| ~~`IDLE_DEADLINE_S`~~ | (removed) | replaced by `SO_KEEPALIVE` |

The settings UI (`ui/settings_dialog.rb`) is **not** changed; it does
not surface any of these constants today and shouldn't start now.

## 10. Testing

### 10.1 Ruby unit tests (`test/test_server_multi_client.rb`, new file)

Pattern carried over from `test/test_server_compat.rb`:
captured-write fake sockets with explicit chunk feeding. A small
`FakeSocket` helper:

```ruby
class FakeSocket
  attr_reader :written
  def initialize(read_queue = [])
    @read_queue = read_queue   # Array of bytes-strings
    @written = String.new(encoding: Encoding::ASCII_8BIT)
    @closed = false
  end
  def read_nonblock(_n)
    raise IO::WaitReadable if @read_queue.empty?
    @read_queue.shift
  end
  def write(bytes); @written << bytes.b; bytes.bytesize; end
  def flush; end
  def close; @closed = true; end
  def closed?; @closed; end
  def peeraddr; ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"]; end
end
```

`IO.select` is monkey-patched per test to "always ready for write".

Cases:

1. **Handshake happy path** — feed `hello` frame, expect success
   response with `server_version` and `client_id`. `handshaked = true`.
2. **Handshake — version mismatch** — feed `hello` with bad version,
   expect `-32001` envelope written **then** socket closed.
3. **Handshake — wrong first method** — feed `tools/call` first, expect
   `-32600` envelope then close.
4. **Handshake — missing params.client_version** — `-32602` then close.
5. **Post-handshake tools/call** — feed `hello` + `get_model_info`,
   expect both responses.
6. **Two clients, one frame each** — both write responses in order they
   were dispatched (i.e. order of decoded-frame arrival).
7. **Two clients, A pipelines 3 + B sends 1** — verify A's 3
   responses, then B's 1, in that order (FIFO by decode order; A first
   in `@clients` hash iteration).
8. **Disconnect mid-queue** — A is first; A1 dispatched; we mark A's
   socket closed; remaining A2, A3 are skipped; B's frame still
   processed.
9. **Write timeout one client** — A's write fails (`IO.select` returns
   nil); A is closed; B continues.
10. **Frame parse error one client** — A sends invalid JSON;
    `-32700` envelope to A, A closed; B continues.
11. **`SO_KEEPALIVE` setsockopt called on accept** — assert the option
    is set on every accepted socket (use a fake `accept_nonblock` that
    records `setsockopt` invocations).
12. **No idle-deadline path exists** — assert by sending zero frames for
    "a long simulated time" and showing client is NOT closed (mock
    `Time.now`).
13. **Server-level error in `on_timer_tick`** — inject a poison
    `accept_nonblock` that raises; assert no client is reset, error is
    logged.
14. **`prompts/list` returns method-not-found** — confirms removal of
    the dormant branch (post-handshake regular `tools/call` envelope
    pointing at `prompts/list` returns `-32601`).

### 10.2 Ruby `test/test_server_compat.rb` (rewrite)

Existing single-client tests are recast to use the handshake-first
flow. The "version is checked on every request" tests are deleted (the
behaviour no longer exists). Tests that simply confirm the per-tool
dispatch still work get a `hello` frame prepended.

### 10.3 Python unit tests (`tests/test_connection.py`)

- `test_handshake_happy_path` — fake server accepts, replies success.
  Assert `_server_version`, `_client_id` are populated.
- `test_handshake_version_mismatch` — fake server replies `-32001` and
  closes; assert `IncompatibleVersionError` raised, writer closed.
- `test_handshake_failure_propagates` — generic `-32000` error; assert
  `SketchUpError` raised with code preserved.
- `test_send_once_does_not_include_client_version` — assert outbound
  request body has no `client_version` field.
- `test_send_once_does_not_check_server_version` — fake server omits
  `server_version`; request still succeeds. (Important: handshake
  already covered it; per-request check would re-introduce overhead.)
- `test_stale_socket_retry_redoes_handshake` — fake server closes
  socket after one request; second call should reconnect and replay
  handshake before retrying the original request.
- Existing `_RETRY_SAFE_TOOLS` tests stay valid (the list is unchanged).

### 10.4 Live smoke (`examples/smoke_multi_client.py`, new file)

A standalone Python script (does not depend on `pytest`):

```python
"""
Spawn N concurrent Python subprocesses, each opens its own
sketchup_mcp.connection.SketchUpConnection and runs a short scripted
workload against the SketchUp instance.

Asserts:
  - all N subprocesses finish exit-code 0 within global_timeout
  - per-subprocess wall time is within budget × 2 (allows for serial
    execution interference but not starvation)
  - no subprocess emits IncompatibleVersionError or ConnectionError
"""
```

Workloads (one of each across the subprocesses):

- **Light**: `get_model_info` × 10, `list_components` × 5, `get_version`.
  Should complete fast — proves the light client isn't starved.
- **Heavy**: `create_component` (big box) → `boolean_operation` (union
  with another box) → `get_model_info`. Demonstrates the slow-handler
  blocking SketchUp during which the light client must wait but not
  fail.
- **Verbose**: `list_components` in a 30-iteration loop. Stress on the
  read path.

Two of the workloads are run in parallel by default; the script accepts
`--n 3` etc. for higher fan-out.

The smoke does **not** run in CI (SketchUp is GUI-bound). It joins the
existing `examples/smoke_check.py` as a manually-invoked verification
step.

## 11. Documentation updates

`CLAUDE.md` changes:

- **Delete** the "Ruby accepts a single TCP client at a time…" sentence
  in the "Non-Obvious Constraints" section, along with the workaround
  instructions about restarting the plugin / disabling the `sketchup`
  MCP server.
- **Delete** the mention of `IDLE_DEADLINE_S = 300`.
- **Rewrite** the "Version handshake" paragraph from "every request /
  every response" wording to "one-time `hello` exchange on connect".
- **Add** a "Multi-client" paragraph: "Server accepts N concurrent TCP
  clients. Operations are still serialised on the SketchUp UI thread;
  frames are dispatched in a single global FIFO ordered by decode
  arrival. Per-client errors are isolated. Logical races between
  clients on the model are the user's responsibility."
- **Delete** the note about the dormant `prompts/list` branch in the
  "MCP Prompts" section.

`docs/release.md` changes:

- Add a "Breaking change: one-time version handshake" callout for the
  next release. Old Python clients (0.0.x / 0.1.x) will fail to
  handshake against the new server; users must upgrade both halves
  together.

## 12. Out-of-scope (explicit)

- Per-model / per-entity / per-session locking of any kind.
- Optimistic concurrency control, MVCC, snapshot reads.
- Authentication, authorisation, TLS, ACLs.
- Per-client request priorities or quality-of-service knobs.
- Round-robin reads at the byte level for "true TCP arrival order"
  fairness.
- Per-tick processing cap (count or wall-time).
- Re-introducing an idle deadline as an application-level mechanism
  (only `SO_KEEPALIVE` at the OS level).
- Server-push events (e.g. "model changed" notifications) — the
  framing supports it in theory, but no design or use case is in
  scope here.
- Compatibility shims for older Python clients (0.0.x / 0.1.x). They
  will get a clean handshake error and the user upgrades both halves.
- UI / settings dialog changes.

## 13. Risks and open issues

### 13.1 Pipelining starvation

A pathological client that pipelines hundreds of `tools/call` frames in
a single tick will fill the queue ahead of any other client. The other
client's frames decoded later in the same tick still wait behind the
pipeliner's queue tail. This was explicitly accepted by the user as the
FIFO trade-off vs round-robin; round-robin is left as a future option
if real workloads demand it.

### 13.2 SO_KEEPALIVE intervals are OS-level

Default Linux `tcp_keepalive_time = 7200` (2 hours), Windows similar.
Half-open detection therefore takes hours, not seconds. The user has
accepted this as adequate — desktop tool, sole user, regular plugin
restarts. If finer-grained detection is needed later, per-socket
`TCP_KEEPIDLE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT` can be set with one
additional `setsockopt` per option (Linux only; Windows uses
`SIO_KEEPALIVE_VALS` ioctl, which is uglier).

### 13.3 `@close_after_response` instance-variable shim

The handshake-rejection path uses
`state.instance_variable_set(:@close_after_response, true)` as a minimal
"respond then close" flag. If a second "respond then close" use case
appears (e.g. server-initiated graceful shutdown), this should be
promoted to a proper `closing` enum on `ClientState`. Until then the
instance-var avoids a `ClientState` API churn for a one-off case.

### 13.4 Per-request envelope reduction is small

Dropping `client_version` / `server_version` saves ~30 bytes per
roundtrip. The protocol-cleanup motivation is stronger than the
byte-savings motivation; the bandwidth claim should not feature in the
release notes.

### 13.5 Test surface widens significantly

Multi-client adds ~14 new Ruby test cases plus 7 Python ones. The total
test runtime is still trivial (all in-memory), but the **failure
mode space** is wider — review must check that no error path leaves a
client stuck in `@clients` without `close_client`, and no error path
closes the wrong client.

### 13.6 Backward compat exit on TestPyPI

There is no canary/TestPyPI staging step in scope. The handshake change
is a hard breaking flip — users who don't simultaneously upgrade the
`.rbz` will see an `IncompatibleVersionError` on every connect attempt.
For the sole user this is acceptable; for any future external user it
would warrant a deprecation period that this design intentionally
skips.

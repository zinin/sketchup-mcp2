# Multi-client Ruby Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-`@client` slot in `su_mcp/su_mcp/core/server.rb` with a multi-client server (N concurrent TCP connections, global FIFO frame queue, single-threaded dispatch on the SketchUp UI thread). Simultaneously simplify the version-check protocol to a one-time `hello` handshake performed on connect (per-request `client_version` / per-response `server_version` removed).

**Architecture:** `Server` maintains `@clients = {sock => ClientState}` and a global `@frame_queue = [[ClientState, body], …]`. Each `UI.start_timer` tick: (1) drain TCP backlog into new `ClientState` entries, (2) read pending bytes from every client via per-client `FrameReader`, push decoded frames to `@frame_queue`, (3) dispatch queued frames FIFO. The first frame from any client MUST be JSON-RPC method `hello` carrying `client_version`; server responds with `server_version` and assigned `client_id`. After handshake, regular `tools/call` requests carry no version fields. Per-client errors (parse / write timeout / handshake violation / framing) close only that client; the queue, other clients, and the server itself keep running.

**Tech Stack:**
- Ruby 2.7+ (SketchUp 2026 extension; stdlib `socket`, `json`, `minitest`; no gem dependencies)
- Python 3.13 (FastMCP, asyncio, pytest)
- No new gems / no new pip dependencies

---

## File Structure

**Created:**
- `su_mcp/su_mcp/core/client_state.rb` — per-connection state class
- `test/test_client_state.rb` — unit tests for ClientState
- `test/test_logger.rb` — unit tests for Logger keyword arg
- `test/support/fake_socket.rb` — shared FakeSocket helper for server tests
- `test/test_server_multi_client.rb` — multi-client server tests (uses FakeSocket)
- `test/test_server_handshake.rb` — handshake-flow tests (uses FakeSocket)
- `examples/smoke_multi_client.py` — live multi-client smoke (manual, runs against running SketchUp)

**Modified:**
- `su_mcp/su_mcp/main.rb` — `require_relative` the new `client_state.rb`
- `su_mcp/su_mcp/core/server.rb` — major rewrite (single → multi-client, handshake gate, SO_KEEPALIVE, IDLE removed)
- `su_mcp/su_mcp/core/logger.rb` — add optional `client_label:` keyword to `log_tool`/`log_error`
- `su_mcp/su_mcp/handlers/dispatch.rb` — remove per-request version check, remove `get_version` bypass, remove dormant `resources/list` / `prompts/list` branches
- `su_mcp/su_mcp/core/compat.rb` — adjust error wording (no more "every request carries client_version")
- `src/sketchup_mcp/connection.py` — add `_handshake()` in `connect()`, drop `client_version` from per-request envelope, drop per-response `server_version` check
- `src/sketchup_mcp/compat.py` — adjust error wording
- `test/test_server_compat.rb` → **renamed** to `test/test_dispatch_post_handshake.rb` and rewritten (drop version-check cases; assert post-handshake dispatch semantics)
- `tests/test_connection.py` — rewrite for handshake roundtrip, drop `client_version` assertions
- `tests/test_version_handshake.py` — rewrite for one-time handshake semantics
- `tests/test_version_tool.py` — minor cleanup (get_version tool stays, but no longer "bypass diagnostic")
- `CLAUDE.md` — multi-client section, updated version handshake paragraph, removed `IDLE_DEADLINE_S` / restart-plugin / `prompts/list` mentions
- `docs/release.md` — breaking-change note for the next release

**Deleted:** none.

---

## Pre-flight

- [ ] **P1: Confirm working directory and branch**

```bash
cd /opt/github/zinin/sketchup-mcp2
git rev-parse --abbrev-ref HEAD
# Expected: feature/multi-client-server

git status --short
# Expected: design doc + plan doc are the only changes (or already committed)
```

- [ ] **P2: Establish baseline test counts**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: 189 runs / 428 assertions / 0 failures / 0 errors (pre-change baseline)

uv run pytest tests/ -q 2>&1 | tail -3
# Expected: 119 passed
```

If baseline numbers don't match, **stop** and reconcile before continuing — the plan assumes a green starting point.

---

## Task 1: `ClientState` class

**Files:**
- Create: `su_mcp/su_mcp/core/client_state.rb`
- Create: `test/test_client_state.rb`
- Modify: `su_mcp/su_mcp/main.rb` (require)

- [ ] **Step 1: Write the failing test**

Create `test/test_client_state.rb`:

```ruby
# test/test_client_state.rb — unit tests for ClientState struct.
require "minitest/autorun"
require "socket"

require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/client_state"

class FakeSockForState
  def initialize(peer = ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"], raise_peeraddr: false)
    @peer = peer
    @raise_peeraddr = raise_peeraddr
    @closed = false
  end
  def peeraddr
    raise SocketError, "unconnected" if @raise_peeraddr
    @peer
  end
  def close; @closed = true; end
  def closed?; @closed; end
end

class TestClientState < Minitest::Test
  def test_initialize_assigns_id_and_sock
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(7, sock)
    assert_equal 7, state.id
    assert_same sock, state.sock
  end

  def test_initialize_creates_fresh_frame_reader
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(0, sock)
    assert_kind_of SU_MCP::Core::Framing::FrameReader, state.reader
  end

  def test_label_format_is_id_and_peer
    sock = FakeSockForState.new(["AF_INET", 12345, "192.168.1.10", "192.168.1.10"])
    state = SU_MCP::Core::ClientState.new(3, sock)
    assert_equal "#3[192.168.1.10:12345]", state.label
  end

  def test_label_falls_back_to_unknown_when_peeraddr_raises
    sock = FakeSockForState.new(raise_peeraddr: true)
    state = SU_MCP::Core::ClientState.new(0, sock)
    assert_equal "#0[unknown]", state.label
  end

  def test_handshake_state_starts_false_and_is_mutable
    state = SU_MCP::Core::ClientState.new(0, FakeSockForState.new)
    refute state.handshaked
    assert_nil state.client_version
    state.handshaked = true
    state.client_version = "0.2.0"
    assert state.handshaked
    assert_equal "0.2.0", state.client_version
  end

  def test_closed_delegates_to_sock
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(0, sock)
    refute state.closed?
    sock.close
    assert state.closed?
  end
end
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
ruby test/test_client_state.rb 2>&1 | tail -5
# Expected: LoadError — cannot load such file -- .../core/client_state
```

- [ ] **Step 3: Implement `ClientState`**

Create `su_mcp/su_mcp/core/client_state.rb`:

```ruby
# su_mcp/su_mcp/core/client_state.rb
module SU_MCP
  module Core
    class ClientState
      attr_reader   :id, :sock, :reader, :label
      attr_accessor :handshaked, :client_version

      def initialize(id, sock)
        @id             = id
        @sock           = sock
        @reader         = Framing::FrameReader.new
        @label          = "##{id}[#{peer_label(sock)}]"
        @handshaked     = false
        @client_version = nil
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

- [ ] **Step 4: Hook it into the loader**

Edit `su_mcp/su_mcp/main.rb`. Find the existing `require_relative "core/framing"` line (or similar block of `core/*` requires) and add:

```ruby
require_relative "core/client_state"
```

after `core/framing` (ClientState depends on FrameReader at init time).

- [ ] **Step 5: Run the test and verify it passes**

```bash
ruby test/test_client_state.rb 2>&1 | tail -3
# Expected: 6 runs, 8 assertions, 0 failures, 0 errors
```

- [ ] **Step 6: Run the full Ruby suite**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: 195 runs (189 + 6 new), 436 assertions, 0 failures
```

- [ ] **Step 7: Commit**

```bash
git add su_mcp/su_mcp/core/client_state.rb test/test_client_state.rb su_mcp/su_mcp/main.rb
git commit -m "feat(ruby): add ClientState per-connection state struct

Holds id, sock, FrameReader, label, handshake flag. Used by
upcoming multi-client server refactor."
```

---

## Task 2: `Logger` keyword-arg extension

**Files:**
- Modify: `su_mcp/su_mcp/core/logger.rb`
- Create: `test/test_logger.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_logger.rb`:

```ruby
# test/test_logger.rb — verifies client_label: keyword extension to Logger.
require "minitest/autorun"
require "stringio"

require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"

class TestLogger < Minitest::Test
  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "INFO"
    @captured = StringIO.new
    @orig_stdout = $stdout
    $stdout = @captured
  end

  def teardown
    $stdout = @orig_stdout
  end

  def last_line
    @captured.string.lines.last.to_s.chomp
  end

  def test_log_tool_without_client_label_is_unchanged
    SU_MCP::Core::Logger.log_tool("create_component", "ok")
    assert_match(/tool=create_component status=ok\z/, last_line)
  end

  def test_log_tool_with_extra_positional_still_works
    SU_MCP::Core::Logger.log_tool("create_component", "ok", "bbox_mm=[1,2,3]")
    assert_match(/tool=create_component status=ok bbox_mm=\[1,2,3\]\z/, last_line)
  end

  def test_log_tool_with_client_label_prepends_segment
    SU_MCP::Core::Logger.log_tool("server", "client_connected",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(/tool=server status=client_connected client=#0\[127\.0\.0\.1:54321\]\z/, last_line)
  end

  def test_log_tool_with_label_and_extra
    SU_MCP::Core::Logger.log_tool("server", "client_disconnected",
      "reason=write_timeout",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(
      /tool=server status=client_disconnected client=#0\[127\.0\.0\.1:54321\] reason=write_timeout\z/,
      last_line)
  end

  def test_log_error_without_client_label_is_unchanged
    err = RuntimeError.new("boom")
    SU_MCP::Core::Logger.log_error("server.timer", err)
    assert_match(/tool=server\.timer class=RuntimeError msg=boom\z/, last_line)
  end

  def test_log_error_with_client_label_prepends_segment
    err = RuntimeError.new("boom")
    SU_MCP::Core::Logger.log_error("server.parse", err,
      client_label: "#1[127.0.0.1:54321]")
    assert_match(
      /tool=server\.parse client=#1\[127\.0\.0\.1:54321\] class=RuntimeError msg=boom\z/,
      last_line)
  end
end
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
ruby test/test_logger.rb 2>&1 | tail -10
# Expected: failures on the 4 client_label cases (ArgumentError: unknown keyword: client_label)
```

- [ ] **Step 3: Extend `Logger`**

Edit `su_mcp/su_mcp/core/logger.rb` — replace `log_tool` and `log_error`:

```ruby
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

- [ ] **Step 4: Run the test and verify it passes**

```bash
ruby test/test_logger.rb 2>&1 | tail -3
# Expected: 6 runs, 6 assertions, 0 failures
```

- [ ] **Step 5: Run the full Ruby suite (regression check)**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: 201 runs (195 + 6 new), 442 assertions, 0 failures
```

If any pre-existing test that called `log_tool(..., 3rd_positional)` now fails, the `extra` argument is being shadowed by the keyword — that would be a bug in this task. Re-read the `log_tool` signature.

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/core/logger.rb test/test_logger.rb
git commit -m "feat(ruby): add client_label: keyword to Logger.log_tool/log_error

Optional; when set, prepends 'client=<label>' segment to the log
body. Existing positional callers unaffected. Used by upcoming
multi-client server logging."
```

---

## Task 3: Simplify `Dispatch` — drop per-request version check, `get_version` bypass, dormant branches

**Files:**
- Modify: `su_mcp/su_mcp/handlers/dispatch.rb`
- Rename + rewrite: `test/test_server_compat.rb` → `test/test_dispatch_post_handshake.rb` (drop version cases, add post-handshake dispatch cases)

**Context:** Today every request to `Dispatch.handle` carries `client_version` and `Dispatch` calls `Core::Compat.check_python_version`. With the upcoming handshake, version verification moves to a one-shot at connect-time (handled in `Server`, not `Dispatch`). `Dispatch` becomes the post-handshake-only path. The dormant `resources/list` / `prompts/list` branches (already never reached because FastMCP serves these Python-side) go away in the same edit.

- [ ] **Step 1: Rename and rewrite `test/test_server_compat.rb` → `test/test_dispatch_post_handshake.rb`**

First, rename the file so its name reflects the new content (compat-specific tests move to `test_server_handshake.rb`):

```bash
git mv test/test_server_compat.rb test/test_dispatch_post_handshake.rb
# If test/run_all.rb references the old name explicitly, update it
# (most run_all.rb implementations use a glob and don't need editing).
grep -nE "test_server_compat" test/run_all.rb || echo "no explicit reference — glob will pick the renamed file"
```

Then replace the **entire renamed file's** contents with:

```ruby
# test/test_dispatch_post_handshake.rb — Dispatch.handle behavior after
# the one-time handshake (no per-request version check). Tests the
# post-handshake protocol surface: tools/call dispatch, unknown methods,
# malformed envelopes, notification handling. Version-handshake logic
# itself is tested in test/test_server_handshake.rb.

require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"

class TestDispatchPostHandshake < Minitest::Test
  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "INFO"
  end

  def make_request(method:, params: {}, id: 1)
    req = {
      "jsonrpc" => "2.0",
      "method"  => method,
      "params"  => params,
    }
    req["id"] = id unless id == :omit
    req
  end

  # --- happy path: tools/call without client_version ---

  def test_dispatch_tools_call_get_version_returns_payload
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      id: 42,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal 42, resp["id"]
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  # --- envelope validation ---

  def test_dispatch_rejects_non_hash_request
    resp = SU_MCP::Handlers::Dispatch.handle("not a hash")
    assert_equal(-32600, resp["error"]["code"])
  end

  def test_dispatch_rejects_wrong_jsonrpc_version
    req = { "jsonrpc" => "1.0", "method" => "tools/call", "id" => 1, "params" => {} }
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32600, resp["error"]["code"])
  end

  def test_dispatch_rejects_empty_method
    req = { "jsonrpc" => "2.0", "method" => "", "id" => 1 }
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32600, resp["error"]["code"])
  end

  # --- tools/call params validation ---

  def test_dispatch_tools_call_requires_params_object
    req = make_request(method: "tools/call", params: nil, id: 1)
    req["params"] = "not a hash"
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32602, resp["error"]["code"])
  end

  def test_dispatch_tools_call_requires_non_empty_name
    req = make_request(method: "tools/call", params: { "name" => "", "arguments" => {} }, id: 1)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32602, resp["error"]["code"])
  end

  def test_dispatch_unknown_tool_returns_method_not_found
    req = make_request(method: "tools/call",
      params: { "name" => "no_such_tool", "arguments" => {} }, id: 1)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
    assert_includes resp["error"]["message"], "unknown tool"
  end

  # --- removed dormant branches: prompts/list, resources/list ---

  def test_dispatch_prompts_list_returns_method_not_found
    req = make_request(method: "prompts/list", id: 1)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
  end

  def test_dispatch_resources_list_returns_method_not_found
    req = make_request(method: "resources/list", id: 1)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
  end

  # --- notifications (no id) return nil ---

  def test_dispatch_notification_returns_nil
    req = make_request(method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      id: :omit)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_nil resp
  end

  # --- no client_version expected, no server_version added by Dispatch ---

  def test_dispatch_response_has_no_server_version_key
    req = make_request(method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} }, id: 1)
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    # server_version injection moves into Server#encode_response_body
    # — Dispatch returns a pure JSON-RPC envelope.
    refute resp.key?("server_version"),
      "Dispatch must not embed server_version; that lives in Server now"
  end
end
```

- [ ] **Step 2: Run the rewritten test and verify it fails**

```bash
ruby test/test_dispatch_post_handshake.rb 2>&1 | tail -10
# Expected: most tests fail. Likely failures:
# - test_dispatch_prompts_list_returns_method_not_found — fails because
#   dispatch.rb still has the "resources/list", "prompts/list" branch.
# - test_dispatch_tools_call_get_version_returns_payload — may pass
#   accidentally (get_version_call bypass still in place).
# - test_dispatch_response_has_no_server_version_key — passes today
#   (server_version is injected by Server, not Dispatch).
```

The exact mix doesn't matter — proceed to step 3.

- [ ] **Step 3: Simplify `dispatch.rb`**

Edit `su_mcp/su_mcp/handlers/dispatch.rb`. Replace the **entire `self.handle(request)` method** with:

```ruby
def self.handle(request)
  request_id = nil
  is_notification = false
  tool = nil
  params = {}
  begin
    validate_envelope!(request)

    request_id = request["id"]
    is_notification = !request.key?("id")
    method = request["method"]

    response_body =
      case method
      when "tools/call"
        call_params = request["params"]
        unless call_params.is_a?(Hash)
          raise Core::StructuredError.new(-32602, "tools/call requires params object")
        end
        tool = call_params["name"]
        unless tool.is_a?(String) && !tool.empty?
          raise Core::StructuredError.new(-32602, "tools/call requires non-empty 'name' string")
        end
        params = call_params["arguments"] || {}
        unless params.is_a?(Hash)
          raise Core::StructuredError.new(-32602, "tools/call 'arguments' must be an object")
        end
        call_handler(tool, params)
      else
        raise Core::StructuredError.new(-32601, "method not found: #{method}")
      end

    return nil if is_notification
    build_success_response(response_body, request_id)
  rescue Core::StructuredError => e
    Core::Logger.log_error(tool || "?", e)
    return nil if is_notification
    Core::Errors.build_error_response(e.code, e.message,
      Core::Errors.exception_to_data(e, tool || "?", params), request_id)
  rescue StandardError => e
    Core::Logger.log_error(tool || "?", e)
    return nil if is_notification
    Core::Errors.build_error_response(-32603, e.message,
      Core::Errors.exception_to_data(e, tool || "?", params), request_id)
  end
end
```

Removed:
- `is_get_version_call` detection
- `unless is_get_version_call` block that called `Core::Compat.check_python_version`
- `when "resources/list", "prompts/list"` branch (now `else → -32601`)
- The special-case logger branch for `e.code == -32001` (no version errors flow through here anymore)

Keep `validate_envelope!`, `build_success_response`, `wrap_content`, `call_handler` unchanged.

- [ ] **Step 4: Run the rewritten test and verify it passes**

```bash
ruby test/test_dispatch_post_handshake.rb 2>&1 | tail -3
# Expected: 11 runs, ~14 assertions, 0 failures
```

- [ ] **Step 5: Run the full Ruby suite (regression check)**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: ~ 192 runs, ~ 425 assertions, 0 failures
# (some previously-existing tests in test_server_compat were deleted;
#  total count drops by the difference between old and new test counts)
```

If any other Ruby test fails, it likely depends on the removed `client_version` plumbing in `Dispatch`. Inspect the failure and either delete the obsolete test or update it to the post-handshake semantics — the same kind of cleanup we did for `test_server_compat.rb`.

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/handlers/dispatch.rb test/test_dispatch_post_handshake.rb
# `git mv` from Step 1 already staged the rename; the new file is at
# test/test_dispatch_post_handshake.rb in the index.
git commit -m "refactor(ruby): drop per-request version check and dormant branches from Dispatch

Per-request client_version verification moves to Server's connect-time
handshake (next commit). 'resources/list' / 'prompts/list' dormant
branches removed — FastMCP serves them Python-side, Ruby never receives
them. Dispatch now handles only tools/call.

test_server_compat.rb rewritten to cover post-handshake Dispatch semantics."
```

---

## Task 4: Multi-client `Server` rewrite (without handshake gate yet)

**Files:**
- Modify: `su_mcp/su_mcp/core/server.rb` (major rewrite)
- Create: `test/support/fake_socket.rb` (shared helper)
- Create: `test/test_server_multi_client.rb` (multi-client unit tests)

**Context:** This task moves `Server` from single-`@client` to multi-`@clients`, introduces the global FIFO `@frame_queue`, and refactors per-client error isolation. **No handshake gate yet** — every incoming frame is dispatched straight to `Dispatch.handle`. The handshake is added in Task 5.

After this task: multiple Python clients can connect simultaneously and call `tools/call` directly (no `hello` required yet). The protocol is in an intermediate state — fully multi-client but without version verification (Task 3 removed it from Dispatch; Task 5 adds it back at connect). This intermediate state is OK because:
- Old Python clients still work (they're being updated in Task 6 anyway; and a Python client that includes `client_version` field just sees it ignored by the simpler Dispatch).
- Branch is unmerged; only the author runs against it.

- [ ] **Step 1: Create the `FakeSocket` helper**

Create `test/support/fake_socket.rb`:

```ruby
# test/support/fake_socket.rb — minimal in-memory socket stub for server tests.
# Behaves like a TCPSocket from the Server's perspective:
#   - read_nonblock(n) pops from queued chunks; raises IO::WaitReadable when empty
#   - write(bytes) appends to a captured buffer
#   - close / closed? track state
#   - peeraddr returns a deterministic [family, port, hostname, ip] tuple
#   - setsockopt is recorded (for SO_KEEPALIVE assertions in later tasks)

class FakeSocket
  attr_reader :written, :sockopts

  def initialize(read_chunks: [], peer: ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"])
    @read_queue = read_chunks.dup
    @peer       = peer
    @written    = String.new(encoding: Encoding::ASCII_8BIT)
    @sockopts   = []
    @closed     = false
    @eof        = false
  end

  # Feed more bytes into the read queue mid-test (simulates kernel buffer
  # filling after additional client traffic).
  def push_read(bytes)
    @read_queue << bytes.dup.force_encoding(Encoding::ASCII_8BIT)
  end

  # Mark next read as EOF (peer closed cleanly).
  def push_eof
    @eof = true
  end

  def read_nonblock(_n)
    if @closed
      raise IOError, "closed stream"
    end
    if @read_queue.empty?
      if @eof
        raise EOFError, "end of file reached"
      end
      raise IO::WaitReadable, "Resource temporarily unavailable"
    end
    @read_queue.shift
  end

  def write(bytes)
    raise Errno::EPIPE, "Broken pipe" if @closed
    @written << bytes.b
    bytes.bytesize
  end

  def flush; end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  def peeraddr
    raise SocketError, "unconnected" if @closed
    @peer
  end

  def setsockopt(level, opt, value)
    @sockopts << [level, opt, value]
  end
end

# FakeServer — stand-in for TCPServer.  accept_nonblock pops from queued sockets.
class FakeServer
  def initialize(pending = [])
    @pending = pending.dup
    @closed  = false
  end

  def queue_accept(sock)
    @pending << sock
  end

  def accept_nonblock
    raise IO::WaitReadable, "no pending" if @pending.empty?
    @pending.shift
  end

  def close
    @closed = true
  end
end
```

- [ ] **Step 2: Write the failing multi-client tests**

Create `test/test_server_multi_client.rb`:

```ruby
# test/test_server_multi_client.rb — Server multi-client unit tests.
# Uses FakeSocket + FakeServer + monkey-patched IO.select to drive the tick.
require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/client_state"
require_relative "../su_mcp/su_mcp/core/server"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"
require_relative "support/fake_socket"

# Helper for forging a Length-prefixed JSON-RPC frame.
def fr(obj)
  body = JSON.generate(obj)
  [body.bytesize].pack("N") + body
end

# Parse all frames from a buffer of concatenated length-prefixed responses.
def all_frames(bytes)
  bytes = bytes.dup.force_encoding(Encoding::ASCII_8BIT)
  out = []
  until bytes.empty?
    len = bytes.byteslice(0, 4).unpack1("N")
    out << JSON.parse(bytes.byteslice(4, len))
    bytes = bytes.byteslice(4 + len..-1) || ""
  end
  out
end

class TestServerMultiClient < Minitest::Test
  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "ERROR"   # silence INFO chatter

    # Always-ready writes; per-test override when testing write_timeout.
    SU_MCP::Core::Server.send(:remove_const, :IO_SELECT_STUB) if SU_MCP::Core::Server.const_defined?(:IO_SELECT_STUB)
  end

  # Build a Server with a FakeServer in place of TCPServer and run a
  # single tick. Returns the server instance for further inspection.
  def run_one_tick(fake_server)
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)

    # Force IO.select to always be ready for writes during this tick.
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end

    srv.send(:on_timer_tick)
    srv
  end

  # ---------- Accept loop ----------

  def test_accept_drains_backlog_in_one_tick
    fs = FakeServer.new
    a = FakeSocket.new
    b = FakeSocket.new
    fs.queue_accept(a)
    fs.queue_accept(b)
    srv = run_one_tick(fs)
    assert_equal 2, srv.instance_variable_get(:@clients).size
  end

  def test_each_accepted_client_gets_unique_monotonic_id
    fs = FakeServer.new
    fs.queue_accept(FakeSocket.new)
    fs.queue_accept(FakeSocket.new)
    fs.queue_accept(FakeSocket.new)
    srv = run_one_tick(fs)
    ids = srv.instance_variable_get(:@clients).values.map(&:id).sort
    assert_equal [0, 1, 2], ids
  end

  # ---------- Single-client dispatch (sanity post-rewrite) ----------

  def test_single_client_dispatches_get_version
    req = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    sock = FakeSocket.new(read_chunks: [req])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal 1, frames[0]["id"]
    refute_nil frames[0]["result"]
  end

  # ---------- Global FIFO across clients ----------

  def test_fifo_across_two_clients_each_one_frame
    req_a = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 100)
    req_b = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 200)
    a = FakeSocket.new(read_chunks: [req_a])
    b = FakeSocket.new(read_chunks: [req_b])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert_equal [100], all_frames(a.written).map { |f| f["id"] }
    assert_equal [200], all_frames(b.written).map { |f| f["id"] }
  end

  def test_pipelined_frames_from_one_client_processed_before_next_client
    # A pipelines 3 frames, B has 1 frame. With per-client drain order
    # A-then-B, A's three responses go out before B's one.
    a_chunks = (1..3).map { |i|
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => i)
    }
    b_chunk = fr("jsonrpc" => "2.0", "method" => "tools/call",
                 "params" => { "name" => "get_version", "arguments" => {} },
                 "id" => 99)
    a = FakeSocket.new(read_chunks: [a_chunks.join])
    b = FakeSocket.new(read_chunks: [b_chunk])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert_equal [1, 2, 3], all_frames(a.written).map { |f| f["id"] }
    assert_equal [99],      all_frames(b.written).map { |f| f["id"] }
  end

  # ---------- Per-client error isolation ----------

  def test_eof_on_one_client_does_not_close_others
    a = FakeSocket.new
    a.push_eof
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 1)
    b = FakeSocket.new(read_chunks: [b_req])
    fs = FakeServer.new([a, b])
    srv = run_one_tick(fs)
    assert a.closed?, "A should be closed on EOF"
    refute b.closed?, "B should remain connected"
    # B got its response.
    assert_equal [1], all_frames(b.written).map { |f| f["id"] }
  end

  def test_parse_error_on_one_client_closes_only_that_client
    bad = "garbage{{{not-json"
    bad_frame = [bad.bytesize].pack("N") + bad
    a = FakeSocket.new(read_chunks: [bad_frame])
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 7)
    b = FakeSocket.new(read_chunks: [b_req])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    # A received the -32700 envelope before being closed.
    frames_a = all_frames(a.written)
    assert_equal 1, frames_a.size
    assert_equal(-32700, frames_a[0]["error"]["code"])
    assert_equal [7], all_frames(b.written).map { |f| f["id"] }
  end

  def test_framing_oversize_closes_only_that_client
    # forge a length prefix that exceeds MAX_MESSAGE_SIZE
    over = SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1
    bad_frame = [over].pack("N")  # header only — Server should reject before body
    a = FakeSocket.new(read_chunks: [bad_frame])
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 9)
    b = FakeSocket.new(read_chunks: [b_req])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    assert_equal [9], all_frames(b.written).map { |f| f["id"] }
  end

  def test_disconnect_mid_queue_skips_remaining_pending_frames
    # A pipelines 3 frames. Patch handle_frame to close A's socket after
    # the first dispatch — the remaining 2 must NOT execute responses
    # (their sock.closed? check skips them).
    a_chunks = (1..3).map { |i|
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => i)
    }
    a = FakeSocket.new(read_chunks: [a_chunks.join])
    fs = FakeServer.new([a])
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end

    # Wrap write_response to close A right after the first write.
    closed_after = nil
    orig = SU_MCP::Core::Server.instance_method(:write_response)
    SU_MCP::Core::Server.send(:define_method, :write_response) do |state, response|
      orig.bind(self).call(state, response)
      if closed_after.nil?
        closed_after = response["id"]
        send(:close_client, state, "test_force_close")
      end
    end

    begin
      srv.send(:on_timer_tick)
    ensure
      SU_MCP::Core::Server.send(:define_method, :write_response, orig)
    end

    assert_equal [1], all_frames(a.written).map { |f| f["id"] },
      "only the first response should have been written; A2 and A3 were skipped"
    assert a.closed?
  end

  def test_server_level_error_in_tick_does_not_reset_clients
    # Inject a poison accept_nonblock that raises a non-IO::WaitReadable
    # exception. Server should log and continue; no client should be reset.
    fs = FakeServer.new
    def fs.accept_nonblock
      raise StandardError, "synthetic"
    end
    sock = FakeSocket.new
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    state = SU_MCP::Core::ClientState.new(0, sock)
    srv.instance_variable_get(:@clients)[sock] = state

    srv.send(:on_timer_tick)
    refute sock.closed?, "existing client must NOT be reset by server-level error"
    assert_equal 1, srv.instance_variable_get(:@clients).size
  end
end
```

- [ ] **Step 3: Run the new tests and verify they fail**

```bash
ruby test/test_server_multi_client.rb 2>&1 | tail -20
# Expected: every test errors. Likely first error: NoMethodError /
# missing `io_select_writable?`, or @clients is nil, etc. — because
# Server still has the old single-@client structure.
```

- [ ] **Step 4: Rewrite `core/server.rb`**

Replace the **entire file** contents with:

```ruby
# su_mcp/su_mcp/core/server.rb
require "json"
require "socket"

module SU_MCP
  module Core
    class Server
      TIMER_INTERVAL          = 0.1     # seconds between ticks
      READ_CHUNK              = 64 * 1024
      READ_MAX_ITERATIONS     = 50      # per client per tick
      WRITE_SELECT_TIMEOUT_S  = 1.0     # write probe (per client per write)

      def initialize
        @server         = nil
        @clients        = {}    # sock => ClientState
        @frame_queue    = []    # [[ClientState, body_bytes], ...]
        @next_client_id = 0
        @running        = false
        @timer_id       = nil
        @processing     = false
      end

      def start
        return if @running
        @server = TCPServer.new(Config.host, Config.port)
        @running = true
        @timer_id = ::UI.start_timer(TIMER_INTERVAL, true) { on_timer_tick }
      end

      def stop
        @running = false
        ::UI.stop_timer(@timer_id) if @timer_id
        @timer_id = nil
        @clients.values.each { |state| close_client(state, "server_stop") }
        if @server
          begin
            @server.close
          rescue StandardError
            # ignore — best-effort cleanup
          end
        end
        @server = nil
      end

      private

      def on_timer_tick
        return unless @running
        return if @processing
        @processing = true
        begin
          accept_pending_clients
          drain_reads_all_clients
          process_frame_queue
        rescue StandardError => e
          # Server-level error — log only. Do NOT reset clients.
          Logger.log_error("server.timer", e)
        ensure
          @processing = false
        end
      end

      def accept_pending_clients
        loop do
          begin
            sock = @server.accept_nonblock
          rescue IO::WaitReadable
            return
          rescue Errno::ECONNABORTED
            next   # transient on Windows; try next iteration
          end

          state = ClientState.new(@next_client_id, sock)
          @next_client_id += 1
          @clients[sock] = state
          Logger.log_tool("server", "client_connected",
            client_label: state.label)
        end
      end

      def drain_reads_all_clients
        # snapshot — close_client may modify @clients mid-iteration
        @clients.values.each do |state|
          drain_one_client(state)
        end
      end

      def drain_one_client(state)
        return if state.closed?
        iterations = 0
        loop do
          if iterations >= READ_MAX_ITERATIONS
            return    # process the rest on next tick
          end
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
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream desynced.
        send_transport_error(state, e, nil)
        close_client(state, "framing_error: #{e.message}")
      end

      def process_frame_queue
        until @frame_queue.empty?
          state, body = @frame_queue.shift
          next if state.closed?

          response = handle_frame(state, body)
          if response
            write_response(state, response)
          end
        end
      end

      def handle_frame(state, body)
        request = JSON.parse(body)
        Handlers::Dispatch.handle(request)
      rescue JSON::ParserError => e
        Logger.log_error("server.parse", e, client_label: state.label)
        # JSON-RPC §5.1: parse-error responses use id=null.
        send_transport_error(state,
          StructuredError.new(-32700, "parse error: #{e.message}"), nil)
        close_client(state, "parse_error")
        nil
      rescue StandardError => e
        Logger.log_error("server.handler", e, client_label: state.label)
        rid = request.is_a?(Hash) ? request["id"] : nil
        Errors.build_error_response(-32603, e.message,
          Errors.exception_to_data(e, "?", {}), rid)
      end

      def write_response(state, response)
        body = encode_response_body(response)
        frame = Framing.encode_frame(body)
        unless io_select_writable?(state.sock)
          Logger.log_tool("server", "write_timeout",
            client_label: state.label)
          close_client(state, "write_timeout")
          return
        end
        state.sock.write(frame)
        state.sock.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        close_client(state, "write_failed")
      end

      # Indirection lets test code stub IO.select cleanly.
      def io_select_writable?(sock)
        IO.select(nil, [sock], nil, WRITE_SELECT_TIMEOUT_S)
      end

      def encode_response_body(response)
        response["server_version"] = Core::Compat::SERVER_VERSION if response.is_a?(Hash)
        JSON.generate(response)
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
        Logger.log_error("server.encode", e)
        rid = response.is_a?(Hash) ? response["id"] : nil
        safe_msg = e.message.encode("utf-8", invalid: :replace, undef: :replace)
        fallback = Errors.build_error_response(-32603,
          "response not serializable: #{e.class.name}",
          { "error" => safe_msg }, rid)
        fallback["server_version"] = Core::Compat::SERVER_VERSION
        JSON.generate(fallback)
      end

      def send_transport_error(state, structured_error, request_id)
        return if state.closed?
        response = Errors.build_error_response(structured_error.code,
                                               structured_error.message,
                                               structured_error.data,
                                               request_id)
        write_response(state, response)
      rescue StandardError => e
        Logger.log_error("server.send_transport_error", e,
          client_label: state.label)
      end

      def close_client(state, reason)
        # Idempotent. `@clients` membership is the source of truth for
        # "still tracked"; `state.closed?` only decides whether sock.close
        # is needed. A second call (e.g. drain_one_client after a
        # write_response rescue already evicted the client) is a no-op
        # and does NOT log a duplicate "client_disconnected" line.
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
    end
  end
end
```

NB: `encode_response_body` still injects `server_version` on the way out. That's intentional for this task — the handshake (Task 5) is what makes `server_version` redundant on post-handshake responses; we strip it out in Task 5 once the handshake actually exists. Keeping the injection here means Task 4 ends with a clean test run.

- [ ] **Step 5: Run the multi-client tests and verify they pass**

```bash
ruby test/test_server_multi_client.rb 2>&1 | tail -3
# Expected: 10 runs, ~20 assertions, 0 failures
```

If any test fails, the most likely culprits are:
- `handle_frame` rescue path: a test exercises a body the rescue doesn't cover.
- `close_client` ordering inside the test that wraps `write_response` — make sure the wrap is restored in an `ensure` block.

- [ ] **Step 6: Run the full Ruby suite (regression)**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: previous Ruby tests still pass + the new multi-client tests
# Total: ~ 202 runs, ~ 445 assertions, 0 failures
```

Note: if `test_application.rb` exercises start/stop on a real Server, it should still pass (the constants and public API are intact). If it does NOT pass, the failure points at a method whose signature changed during the rewrite — inspect and reconcile.

- [ ] **Step 7: Commit**

```bash
git add su_mcp/su_mcp/core/server.rb test/support/fake_socket.rb test/test_server_multi_client.rb
git commit -m "feat(ruby): multi-client TCP server with per-client error isolation

Replace single-@client slot with @clients hash + global @frame_queue.
Per timer tick: drain TCP backlog, read pending bytes from every
client, push decoded frames to FIFO queue, dispatch.

Per-client errors (parse / write_timeout / framing / EOF) close only
that client; other clients and the queue continue. Server-level errors
in on_timer_tick log only (no client reset).

No handshake gate yet — every frame goes straight to Dispatch (which
no longer checks client_version). Handshake follows in the next commit."
```

---

## Task 5: Handshake gate in `Server`

**Files:**
- Modify: `su_mcp/su_mcp/core/server.rb` (add pre-handshake gate)
- Modify: `su_mcp/su_mcp/core/compat.rb` (error wording only)
- Create: `test/test_server_handshake.rb`

**Context:** Build on the multi-client server from Task 4. Add `state.handshaked` gating in `handle_frame`: pre-handshake frames must be `hello` (carries `client_version`); server validates, replies with `server_version` + `client_id`, marks the connection handshaked. Anything else pre-handshake closes the client. Drop `server_version` injection from `encode_response_body` (handshake already covered it).

- [ ] **Step 1: Write the failing handshake tests**

Create `test/test_server_handshake.rb`:

```ruby
# test/test_server_handshake.rb — connect-time hello handshake.
require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/client_state"
require_relative "../su_mcp/su_mcp/core/server"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"
require_relative "support/fake_socket"

def fr(obj)
  body = JSON.generate(obj)
  [body.bytesize].pack("N") + body
end

def all_frames(bytes)
  bytes = bytes.dup.force_encoding(Encoding::ASCII_8BIT)
  out = []
  until bytes.empty?
    len = bytes.byteslice(0, 4).unpack1("N")
    out << JSON.parse(bytes.byteslice(4, len))
    bytes = bytes.byteslice(4 + len..-1) || ""
  end
  out
end

class TestServerHandshake < Minitest::Test
  COMPAT_PYTHON = SU_MCP::Core::Compat::MIN_PYTHON

  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "ERROR"
  end

  def run_one_tick(fake_server)
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end
    srv.send(:on_timer_tick)
    srv
  end

  def hello_frame(version: COMPAT_PYTHON, id: 0, params_override: :default)
    params =
      if params_override == :default
        { "client_version" => version }
      else
        params_override
      end
    fr("jsonrpc" => "2.0", "method" => "hello", "params" => params, "id" => id)
  end

  # ---------- happy path ----------

  def test_hello_with_compatible_version_succeeds
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal 0, frames[0]["id"]
    refute frames[0].key?("error")
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, frames[0]["result"]["server_version"]
    refute_nil frames[0]["result"]["client_id"]
    refute sock.closed?
    state = srv.instance_variable_get(:@clients).values.first
    assert state.handshaked
    assert_equal COMPAT_PYTHON, state.client_version
  end

  def test_post_handshake_tools_call_works_after_hello
    chunks = [
      hello_frame(id: 0),
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => 1),
    ]
    sock = FakeSocket.new(read_chunks: [chunks.join])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 2, frames.size
    assert_equal 0, frames[0]["id"]
    assert_equal 1, frames[1]["id"]
    refute frames[1].key?("error")
  end

  def test_post_handshake_response_has_no_server_version_field
    chunks = [
      hello_frame(id: 0),
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => 1),
    ]
    sock = FakeSocket.new(read_chunks: [chunks.join])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    # hello response: handshake provides server_version inside result.
    # post-handshake response: no top-level server_version field.
    refute frames[1].key?("server_version"),
      "post-handshake response must not carry server_version (handshake covered it)"
  end

  # ---------- rejection paths ----------

  def test_hello_with_incompatible_version_returns_minus_32001_and_closes
    bad = hello_frame(version: "0.0.0", id: 0)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32001, frames[0]["error"]["code"])
    assert sock.closed?, "client must be closed after version rejection"
  end

  def test_non_hello_first_method_returns_minus_32600_and_closes
    bad = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_includes frames[0]["error"]["message"], "first method must be 'hello'"
    assert sock.closed?
  end

  def test_hello_with_missing_client_version_returns_minus_32602_and_closes
    bad = hello_frame(params_override: {})
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_hello_with_non_hash_params_returns_minus_32602_and_closes
    bad = fr("jsonrpc" => "2.0", "method" => "hello",
             "params" => "not a hash", "id" => 0)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_pre_handshake_notification_closes_silently_no_response
    notif = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} })
    # NB: no "id" key — notification per JSON-RPC §4.1.
    sock = FakeSocket.new(read_chunks: [notif])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    assert sock.closed?
    assert_equal "", sock.written, "no response bytes expected for pre-handshake notification"
  end

  def test_other_clients_unaffected_by_one_clients_handshake_failure
    bad_a = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 1)
    good_b = hello_frame(id: 0)
    a = FakeSocket.new(read_chunks: [bad_a])
    b = FakeSocket.new(read_chunks: [good_b])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    frames_b = all_frames(b.written)
    assert_equal 0, frames_b[0]["id"]
    refute frames_b[0].key?("error")
  end
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

```bash
ruby test/test_server_handshake.rb 2>&1 | tail -10
# Expected: every test fails. Likely failures:
# - test_hello_with_compatible_version_succeeds: hello returns -32601
#   ("method not found") because Dispatch (post-Task-3) doesn't know `hello`.
# - test_non_hello_first_method_returns_...: succeeds (returns OK from
#   Dispatch — Server isn't gating yet).
# - test_post_handshake_response_has_no_server_version_field: still has it.
```

- [ ] **Step 3: Add the handshake gate to `Server`**

Edit `su_mcp/su_mcp/core/server.rb`:

**3a.** Replace `handle_frame` with:

```ruby
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
    handle_pre_handshake(state, request)
  else
    Handlers::Dispatch.handle(request)
  end
rescue JSON::ParserError => e
  Logger.log_error("server.parse", e, client_label: state.label)
  send_transport_error(state,
    StructuredError.new(-32700, "parse error: #{e.message}"), nil)
  close_client(state, "parse_error")
  nil
rescue StandardError => e
  Logger.log_error("server.handler", e, client_label: state.label)
  rid = request.is_a?(Hash) ? request["id"] : nil
  Errors.build_error_response(-32603, e.message,
    Errors.exception_to_data(e, "?", {}), rid)
end
```

**3b.** Add new private methods, just below `handle_frame`:

```ruby
def handle_pre_handshake(state, request)
  unless request.is_a?(Hash) && request["jsonrpc"] == "2.0"
    return reject_handshake(state, request,
      StructuredError.new(-32600, "invalid envelope (pre-handshake)"))
  end
  method = request["method"]

  unless method == "hello"
    return reject_handshake(state, request,
      StructuredError.new(-32600,
        "first method must be 'hello' (got: #{method.inspect})"))
  end

  params = request["params"]
  unless params.is_a?(Hash) && params["client_version"].is_a?(String)
    return reject_handshake(state, request,
      StructuredError.new(-32602,
        "hello requires params.client_version (string)"))
  end

  begin
    Core::Compat.check_python_version(params["client_version"])
  rescue StructuredError => e
    return reject_handshake(state, request, e)
  end

  state.handshaked     = true
  state.client_version = params["client_version"]
  Logger.log_tool("server", "handshake_ok",
    "client_version=#{state.client_version}",
    client_label: state.label)

  # Build a raw JSON-RPC envelope inline — do NOT use
  # Handlers::Dispatch.build_success_response. That wrapper turns
  # `result` into the MCP `tools/call` shape
  # `{content:[{type:text,text:...}], isError:false}`, which would
  # break the Python client's `result.server_version` / `result.client_id`
  # reads on the handshake response.
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
  Logger.log_tool("server", "handshake_rejected",
    "code=#{structured_error.code} msg=#{structured_error.message}",
    client_label: state.label)
  state.close_after_response = true
  Errors.build_error_response(structured_error.code,
    structured_error.message,
    Errors.exception_to_data(structured_error, "hello", {}), rid)
end
```

**3c.** Replace `write_response` so it (a) handles a framing-encode failure (StructuredError from `Framing.encode_frame`) with a small fallback envelope, falling back to closing the client only when even the fallback won't encode, and (b) honors the new `state.close_after_response` accessor (added to `ClientState` in this task — see step 3e below):

```ruby
def write_response(state, response)
  body  = encode_response_body(response)
  frame =
    begin
      Framing.encode_frame(body)
    rescue StructuredError => e
      # Body exceeded the 64 MiB framing cap (or was unexpectedly empty).
      # Per the per-client isolation invariant we still owe the caller a
      # response. Try a small fallback envelope; if that won't encode
      # either, close this client and continue serving the rest.
      Logger.log_error("server.encode_frame", e, client_label: state.label)
      rid = response.is_a?(Hash) ? response["id"] : nil
      fallback = Errors.build_error_response(-32603,
        "response too large for transport",
        Errors.exception_to_data(e, "?", {}), rid)
      begin
        Framing.encode_frame(JSON.generate(fallback))
      rescue StandardError
        close_client(state, "encode_frame_failed")
        return
      end
    end

  unless io_select_writable?(state.sock)
    Logger.log_tool("server", "write_timeout",
      client_label: state.label)
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

**3d.** Replace `encode_response_body` to drop `server_version` injection on post-handshake responses (handshake response keeps it because we put it in `result` ourselves):

```ruby
def encode_response_body(response)
  JSON.generate(response)
rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
  Logger.log_error("server.encode", e)
  rid = response.is_a?(Hash) ? response["id"] : nil
  safe_msg = e.message.encode("utf-8", invalid: :replace, undef: :replace)
  fallback = Errors.build_error_response(-32603,
    "response not serializable: #{e.class.name}",
    { "error" => safe_msg }, rid)
  JSON.generate(fallback)
end
```

- [ ] **Step 4: Update `Core::Compat` error wording**

Edit `su_mcp/su_mcp/core/compat.rb`. Find the error messages emitted by `check_python_version` (they likely reference "every request carries client_version" or similar). Reword to:

```ruby
# Example — adapt to exact strings present in the file:
"Python client version #{client_version} is incompatible with this " \
"server (range: #{MIN_PYTHON}..#{MAX_PYTHON}). Handshake rejected. " \
"Upgrade Python client or .rbz plugin."
```

The key change: drop "every request" / "per-request handshake" phrasing wherever it appears. Keep the version-range error informative. (If you're not sure which message to rewrite, grep for "request" inside `core/compat.rb`.)

- [ ] **Step 5: Run handshake tests and verify they pass**

```bash
ruby test/test_server_handshake.rb 2>&1 | tail -3
# Expected: 9 runs, ~25 assertions, 0 failures
```

- [ ] **Step 6: Run multi-client tests (now they need a hello prepended)**

`test_server_multi_client.rb` from Task 4 was written **without** handshake awareness — every test sends `tools/call` as the first frame. Those tests will now fail because the gate rejects non-`hello` first frames.

Fix it by prepending a `hello` chunk to every test that sends a real request. Add this helper at the top of the test class (next to `fr` / `all_frames`):

```ruby
# In test_server_multi_client.rb — add module-level helper:
HELLO = fr("jsonrpc" => "2.0", "method" => "hello",
           "params" => { "client_version" => SU_MCP::Core::Compat::MIN_PYTHON },
           "id" => 0)
```

Then prepend `HELLO` to every test's `read_chunks` and update the response-parsing assertions to skip the first response (which is the hello reply). Concretely:

For `test_single_client_dispatches_get_version`:
```ruby
sock = FakeSocket.new(read_chunks: [HELLO + req])
# ...
frames = all_frames(sock.written)
assert_equal 2, frames.size                # hello reply + get_version reply
assert_equal 0, frames[0]["id"]            # hello id
assert_equal 1, frames[1]["id"]            # get_version id
refute_nil frames[1]["result"]
```

For `test_fifo_across_two_clients_each_one_frame`:
```ruby
a = FakeSocket.new(read_chunks: [HELLO + req_a])
b = FakeSocket.new(read_chunks: [HELLO + req_b])
# ...
ids_a = all_frames(a.written).map { |f| f["id"] }
ids_b = all_frames(b.written).map { |f| f["id"] }
assert_equal [0, 100], ids_a   # hello reply + get_version reply
assert_equal [0, 200], ids_b
```

For `test_pipelined_frames_from_one_client_processed_before_next_client`:
```ruby
a = FakeSocket.new(read_chunks: [HELLO + a_chunks.join])
b = FakeSocket.new(read_chunks: [HELLO + b_chunk])
# ...
assert_equal [0, 1, 2, 3], all_frames(a.written).map { |f| f["id"] }
assert_equal [0, 99],      all_frames(b.written).map { |f| f["id"] }
```

For `test_eof_on_one_client_does_not_close_others`:
```ruby
b = FakeSocket.new(read_chunks: [HELLO + b_req])
# ...
ids_b = all_frames(b.written).map { |f| f["id"] }
assert_equal [0, 1], ids_b
```

For `test_parse_error_on_one_client_closes_only_that_client`:
- A still sends garbage as its first bytes — that's a parse-error in the framing/json layer, which closes A. No hello needed.
- B keeps the `HELLO + b_req` chunks.
- Adjust assertion to `assert_equal [0, 7]` for B's frames.

For `test_framing_oversize_closes_only_that_client`: same as parse-error case.

For `test_disconnect_mid_queue_skips_remaining_pending_frames`: the
intent of this test — verifying that **post-handshake** queue skipping
works when the dispatching client is closed mid-queue — needs to be
preserved. The naive prepend of `HELLO` would let the test wrap fire on
the *handshake* reply instead of A1, defeating the test. Update the
wrap so that it only fires on the FIRST post-handshake response (i.e.
when `response["id"]` is not the handshake `id=0`):

```ruby
a = FakeSocket.new(read_chunks: [HELLO + a_chunks.join])
# Wrap write_response so it closes A right after the first *post-handshake*
# write. Hello reply (id=0) is allowed through; A1 (id=1) is the trigger;
# A2 and A3 should be skipped because state.closed? becomes true.
closed_after = nil
orig = SU_MCP::Core::Server.instance_method(:write_response)
SU_MCP::Core::Server.send(:define_method, :write_response) do |state, response|
  orig.bind(self).call(state, response)
  if closed_after.nil? && response["id"] != 0
    closed_after = response["id"]
    send(:close_client, state, "test_force_close")
  end
end
# ...
assert_equal [0, 1], all_frames(a.written).map { |f| f["id"] },
  "hello reply + A1 reply only — A2 and A3 skipped after force_close"
assert a.closed?
```

For `test_server_level_error_in_tick_does_not_reset_clients`: unchanged — that test doesn't send any frames at all, just checks that an existing `ClientState` survives.

- [ ] **Step 7: Run the updated multi-client tests**

```bash
ruby test/test_server_multi_client.rb 2>&1 | tail -3
# Expected: 10 runs, ~25 assertions, 0 failures
```

If any test still fails, the most common cause is forgetting to update the assertion to include the hello reply (id=0) in the expected frame list.

- [ ] **Step 8: Run the full Ruby suite**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: ~ 211 runs (after Task 4 baseline + 9 handshake tests), 0 failures
```

- [ ] **Step 9: Commit**

```bash
git add su_mcp/su_mcp/core/server.rb su_mcp/su_mcp/core/compat.rb \
        test/test_server_handshake.rb test/test_server_multi_client.rb
git commit -m "feat(ruby): one-time hello handshake gate in Server

First frame from any client must be JSON-RPC method 'hello' with
params.client_version. Server validates against Core::Compat, replies
with server_version + client_id, marks state.handshaked = true.
Subsequent requests dispatch normally without per-request version check.

Rejections (wrong method, missing param, version mismatch) send the
error envelope then close the client. Pre-handshake notifications
close silently per JSON-RPC §4.1.

server_version no longer auto-injected in encode_response_body — the
handshake response carries it once.

test_server_multi_client tests updated to prepend a hello frame."
```

---

## Task 6: Python — `_handshake()` on connect; drop per-request `client_version`

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (add `_handshake()`, drop per-request `client_version`, drop per-response `server_version` check)
- Modify: `src/sketchup_mcp/compat.py` (error wording)
- Modify: `tests/test_connection.py` (rewrite handshake-related tests)
- Modify: `tests/test_version_handshake.py` (rewrite for one-time semantics)
- Modify: `tests/test_version_tool.py` (minor — get_version still exists)

**Context:** Mirror the Ruby handshake on the Python side. `connect()` now performs the `hello` roundtrip before returning; `_send_once` no longer attaches `client_version` to each request, no longer checks `server_version` in each response. Stale-socket retry naturally re-handshakes because retry goes through `connect()`.

- [ ] **Step 1: Read the existing test patterns**

Quickly inspect the existing test scaffolding so the new tests fit the project style:

```bash
head -80 /opt/github/zinin/sketchup-mcp2/tests/test_connection.py
head -40 /opt/github/zinin/sketchup-mcp2/tests/conftest.py
```

This is read-only — you'll write the actual tests in step 2 below, but knowing the file layout (fixture names, how the fake server is structured) will save you false starts.

- [ ] **Step 2: Write the failing Python handshake tests**

Update (or rewrite — your call based on the existing file's organization)
`tests/test_connection.py` to include the following new tests. Keep
unrelated existing tests (framing roundtrip, timeout handling, etc.)
unchanged.

```python
# Place these tests in tests/test_connection.py, after the existing
# fixtures. If conftest.py already provides a `fake_server` style fixture,
# reuse it; otherwise replicate the pattern locally.

import asyncio
import json
import struct

import pytest

from sketchup_mcp import compat
from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError


# ---- Helpers ---------------------------------------------------------------

def encode_frame(body_bytes: bytes) -> bytes:
    return struct.pack(">I", len(body_bytes)) + body_bytes


def hello_success(server_version: str, client_id: int = 0) -> bytes:
    return encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"server_version": server_version, "client_id": client_id},
        "id": 0,
    }).encode("utf-8"))


def hello_error(code: int, message: str) -> bytes:
    return encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": 0,
    }).encode("utf-8"))


class FakeServer:
    """In-process TCP server that scripts the byte stream for one client."""

    def __init__(self, script: list[bytes]):
        self._script = script
        self._received = bytearray()
        self._server: asyncio.base_events.Server | None = None
        self.host = "127.0.0.1"
        self.port = 0   # assigned on listen

    async def __aenter__(self):
        self._server = await asyncio.start_server(
            self._handle, host=self.host, port=0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, reader, writer):
        for chunk in self._script:
            writer.write(chunk)
            await writer.drain()
        # Read whatever the client sends so we can introspect later.
        try:
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                self._received.extend(data)
        except Exception:
            pass
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

    @property
    def received(self) -> bytes:
        return bytes(self._received)


# ---- Tests -----------------------------------------------------------------

@pytest.mark.asyncio
async def test_handshake_happy_path_populates_server_version_and_client_id():
    script = [hello_success(compat.CLIENT_VERSION, client_id=7)]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        assert conn._server_version == compat.CLIENT_VERSION
        assert conn._client_id == 7
        await conn.disconnect()


@pytest.mark.asyncio
async def test_handshake_version_mismatch_raises_incompatible_version_error():
    script = [hello_error(-32001, "client too old")]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        with pytest.raises(IncompatibleVersionError):
            await conn.connect()


@pytest.mark.asyncio
async def test_handshake_generic_error_raises_sketchup_error():
    script = [hello_error(-32602, "handshake malformed")]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
        assert ei.value.code == -32602


@pytest.mark.asyncio
async def test_connect_sends_hello_first_with_client_version():
    script = [hello_success(compat.CLIENT_VERSION)]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        await conn.disconnect()
        # Wait briefly for server-side recv to complete.
        await asyncio.sleep(0.05)
        # First 4 bytes = length, next N = JSON body
        body_len = int.from_bytes(fs.received[:4], "big")
        body = json.loads(fs.received[4:4 + body_len])
        assert body["method"] == "hello"
        assert body["params"]["client_version"] == compat.CLIENT_VERSION
        assert body["id"] == 0


@pytest.mark.asyncio
async def test_send_once_does_not_include_client_version():
    # Script: hello reply, then arbitrary tool reply.
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 1,
    }).encode("utf-8"))
    script = [hello_success(compat.CLIENT_VERSION), tool_reply]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        await conn.send_command("get_version", {})
        await conn.disconnect()
        await asyncio.sleep(0.05)
        # Walk frames in fs.received; the second one is the tools/call body.
        buf = fs.received
        # frame 1: hello
        l1 = int.from_bytes(buf[:4], "big")
        offset = 4 + l1
        # frame 2: tools/call
        l2 = int.from_bytes(buf[offset:offset + 4], "big")
        body = json.loads(buf[offset + 4:offset + 4 + l2])
        assert body["method"] == "tools/call"
        assert "client_version" not in body, \
            "post-handshake request must not carry client_version"


@pytest.mark.asyncio
async def test_send_once_does_not_require_server_version_in_response():
    # Tool reply omits server_version — should still succeed.
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 1,
    }).encode("utf-8"))
    script = [hello_success(compat.CLIENT_VERSION), tool_reply]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        result = await conn.send_command("get_version", {})
        assert result["isError"] is False
        await conn.disconnect()
```

Also: scan `tests/test_version_handshake.py` for tests asserting
per-request `client_version` in outbound bodies or per-response
`server_version` checks. Each such test should either be deleted (the
behavior is gone) or rewritten to assert the one-time-handshake variant.
Concretely, delete tests that fall into either of these shapes:

- "Outbound request body has key `client_version`" → delete; new
  `test_send_once_does_not_include_client_version` covers the inverse.
- "Server reply with missing `server_version` raises X" → delete; new
  `test_send_once_does_not_require_server_version_in_response` covers
  the inverse.

For `tests/test_version_tool.py`: `get_version` still exists as a normal
tool, and its returned payload still contains both versions. The only
likely change is removing any reference to "bypass" semantics in
docstrings or assertions.

- [ ] **Step 3: Run the new Python tests and verify they fail**

```bash
uv run pytest tests/test_connection.py -v -k "handshake or send_once" 2>&1 | tail -20
# Expected: all the new tests fail. Likely failures:
# - test_handshake_happy_path: AttributeError on `_server_version` /
#   `_client_id` (those attributes don't exist yet); or
#   AsyncIO mismatch because connect() doesn't do handshake yet.
# - test_send_once_does_not_include_client_version: assertion fails
#   because client_version IS still in the body.
```

- [ ] **Step 4: Modify `connection.py`**

Open `src/sketchup_mcp/connection.py`. Apply the following changes:

**4a.** Add the new attributes to the `__post_init__` block (after the existing `_lock = asyncio.Lock()` line):

```python
def __post_init__(self) -> None:
    self._lock = asyncio.Lock()
    self._server_version: str | None = None
    self._client_id: int | None = None
```

**4b.** Replace `connect()` (note the explicit `asyncio.wait_for` around the handshake — without it, a Ruby server that accepts TCP but never replies would block `_recv_frame` indefinitely):

```python
async def connect(self) -> None:
    self._reader, self._writer = await asyncio.open_connection(
        self.host, self.port
    )
    try:
        await asyncio.wait_for(self._handshake(), timeout=self.timeout)
    except asyncio.TimeoutError:
        await self.disconnect()
        raise SketchUpError(-32000,
            f"handshake timed out after {self.timeout}s") from None
    except Exception:
        await self.disconnect()
        raise
```

**4c.** Add a new method `_handshake()` just below `connect()`. Note the
defensive normalization: every malformed-envelope path (non-dict, missing
`error` dict shape, missing `result` dict shape, JSON decode failure) is
funneled into `SketchUpError` so callers catch a single class:

```python
async def _handshake(self) -> None:
    request = {
        "jsonrpc": "2.0",
        "method": "hello",
        "params": {"client_version": compat.CLIENT_VERSION},
        "id": 0,
    }
    body = json.dumps(request).encode("utf-8")
    if self._writer is None:
        raise SketchUpError(-32603, "internal: writer is None in _handshake")
    self._writer.write(struct.pack(">I", len(body)) + body)
    await self._writer.drain()
    response_body = await self._recv_frame()
    try:
        response = json.loads(response_body)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32700, f"handshake parse error: {e}") from e
    if not isinstance(response, dict):
        raise SketchUpError(
            -32603,
            f"malformed handshake response: {type(response).__name__}",
        )
    if "error" in response:
        err = response["error"] if isinstance(response.get("error"), dict) else {}
        code = err.get("code", -32000)
        if code == -32001:
            raise IncompatibleVersionError(err.get("message", "version mismatch"))
        raise SketchUpError(code, err.get("message", "handshake failed"),
                            err.get("data"))
    result = response.get("result") or {}
    if not isinstance(result, dict):
        raise SketchUpError(-32603,
            f"malformed handshake result: {type(result).__name__}")
    server_version = result.get("server_version")
    self._server_version = server_version
    self._client_id = result.get("client_id")
    # Belt-and-suspenders: Ruby validated, we validate too. Cheap.
    compat.check_ruby_version(server_version)
```

**4d.** Modify `_send_once()` — drop `client_version` from the outbound body and drop `check_ruby_version` from the response path. Keep the rest of the function intact (timeout handling, id-mismatch check, error envelope handling).

Specifically:

- Remove the line that adds `"client_version": compat.CLIENT_VERSION` to the `request` dict.
- Remove the `if name != "get_version": compat.check_ruby_version(response.get("server_version"))` block.

The post-edit `_send_once` request construction becomes:

```python
request = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": name, "arguments": args},
    "id": rid,
}
```

And the response handling continues to do id-match + error promotion, but **no version check**.

- [ ] **Step 5: Adjust `compat.py` error wording**

`grep` for "every request" / "per-request" / "handshake on every" in `src/sketchup_mcp/compat.py` and rephrase those messages to match the new one-time semantics. The matched-pair version range and `check_ruby_version` function stay; only wording changes.

- [ ] **Step 6: Run the new tests and verify they pass**

```bash
uv run pytest tests/test_connection.py -v -k "handshake or send_once" 2>&1 | tail -20
# Expected: all 6 new tests pass
```

- [ ] **Step 7: Run the full Python suite (regression)**

```bash
uv run pytest tests/ -q 2>&1 | tail -10
# Expected: passing test count near the pre-change baseline minus any
# now-obsolete tests you removed in step 2 (likely 3–6 tests deleted
# from test_version_handshake.py).
# Total: ~ 110-115 passed, 0 failed
```

If a non-`test_connection` test fails:
- Look at `tests/test_tools.py` — if it stubs out `connection.send_command`, it should still work; if it asserts on outbound wire bytes, update like in step 2.
- Look at `tests/conftest.py` — if there's a fixture that builds a fake connection and pre-populates `_server_version`, it may need to call `_handshake()` or set `_server_version` manually.

- [ ] **Step 8: Commit**

```bash
git add src/sketchup_mcp/connection.py src/sketchup_mcp/compat.py \
        tests/test_connection.py tests/test_version_handshake.py \
        tests/test_version_tool.py
git commit -m "feat(python): one-time hello handshake on connect

connect() now performs the hello roundtrip before returning. Outbound
tool requests no longer carry client_version; inbound tool responses
no longer require server_version. Stale-socket retry naturally redoes
the handshake because retry goes through connect().

IncompatibleVersionError surfaced from handshake's -32001 reply.
check_ruby_version still called once at handshake completion (belt-
and-suspenders against Python/Ruby compat range drift).

Python and Ruby halves now both speak the new one-time-handshake
protocol; end-to-end works again."
```

---

## Task 7: `SO_KEEPALIVE` on accepted sockets

**Files:**
- Modify: `su_mcp/su_mcp/core/server.rb` (one line in `accept_pending_clients`)
- Modify: `test/test_server_multi_client.rb` (add SO_KEEPALIVE assertion)

**Context:** With `IDLE_DEADLINE_S` removed (no application-level idle timeout — that was already accomplished in Task 4 because we never re-added the constant during the rewrite), half-open sockets need OS-level detection. `SO_KEEPALIVE` enabled on each accepted socket → Linux/Windows kernel sends keepalive probes after ~2 hours of silence; failed probes close the socket, which we'll see as `ECONNRESET` on next read.

- [ ] **Step 1: Write the failing test**

Append to `test/test_server_multi_client.rb`:

```ruby
  def test_so_keepalive_set_on_accepted_socket
    sock = FakeSocket.new
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    keepalive = sock.sockopts.find { |lvl, opt, _val|
      lvl == Socket::SOL_SOCKET && opt == Socket::SO_KEEPALIVE
    }
    refute_nil keepalive, "SO_KEEPALIVE must be set on every accepted socket"
    assert_equal true, keepalive[2]
  end
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
ruby test/test_server_multi_client.rb -n test_so_keepalive_set_on_accepted_socket 2>&1 | tail -5
# Expected: refute_nil fails — sockopts is empty
```

- [ ] **Step 3: Set `SO_KEEPALIVE` in `accept_pending_clients`**

Edit `su_mcp/su_mcp/core/server.rb`. In `accept_pending_clients`, insert one line right after a successful `accept_nonblock`:

```ruby
def accept_pending_clients
  loop do
    begin
      sock = @server.accept_nonblock
    rescue IO::WaitReadable
      return
    rescue Errno::ECONNABORTED
      next
    end

    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)   # ← new

    state = ClientState.new(@next_client_id, sock)
    @next_client_id += 1
    @clients[sock] = state
    Logger.log_tool("server", "client_connected",
      client_label: state.label)
  end
end
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
ruby test/test_server_multi_client.rb -n test_so_keepalive_set_on_accepted_socket 2>&1 | tail -3
# Expected: 1 run, 2 assertions, 0 failures
```

- [ ] **Step 5: Run the full Ruby suite**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: previous count + 1 = ~ 212 runs, 0 failures
```

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/core/server.rb test/test_server_multi_client.rb
git commit -m "feat(ruby): enable SO_KEEPALIVE on accepted client sockets

IDLE_DEADLINE_S was removed during the multi-client rewrite; OS-level
keepalive (~2h Linux/Windows default) now detects half-open sockets.
Failed keepalive probes surface as ECONNRESET in drain_one_client, which
already closes the affected client without disturbing others."
```

---

## Task 8: Multi-client live smoke test

**Files:**
- Create: `examples/smoke_multi_client.py`

**Context:** Verify end-to-end against a real SketchUp running the new
plugin. Two parallel subprocesses each open their own connection and
do work in parallel; the script asserts both finish without error and
neither starves.

This is **not** run in CI. It is a manual sanity check the developer
runs before merging.

- [ ] **Step 1: Create the script**

Create `examples/smoke_multi_client.py`:

```python
#!/usr/bin/env python3
"""Multi-client live smoke for SketchupMCP.

Spawns N concurrent worker subprocesses; each opens its own
SketchUpConnection against the running SketchUp instance and executes
a short scripted workload. Asserts all workers complete without error.

Usage:
    python examples/smoke_multi_client.py                 # 2 workers
    python examples/smoke_multi_client.py --n 3           # 3 workers
    SKETCHUP_MCP_HOST=192.168.20.20 python examples/smoke_multi_client.py
"""
import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

WORKER_PER_OPERATION_BUDGET = 10.0   # seconds


WORKER_SCRIPT = '''
import asyncio, json, os, sys, time

sys.path.insert(0, %(src_dir)r)

from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp import config

WORKLOAD = %(workload)r
LABEL    = %(label)r

async def main():
    conn = SketchUpConnection(
        host=config.HOST, port=config.PORT, timeout=config.TIMEOUT)
    await conn.connect()
    for step in WORKLOAD:
        t0 = time.monotonic()
        result = await conn.send_command(step["tool"], step["args"])
        dt = time.monotonic() - t0
        print(f"[{LABEL}] {step['tool']:30s} ok dt={dt:.3f}s")
    await conn.disconnect()

asyncio.run(main())
'''


LIGHT_WORKLOAD = (
    [{"tool": "get_version",     "args": {}}] +
    [{"tool": "get_model_info",  "args": {}} for _ in range(8)] +
    [{"tool": "list_components", "args": {}} for _ in range(5)]
)

# NB: HEAVY_WORKLOAD is intentionally simple and self-contained — it
# avoids `boolean_operation` because that tool takes entity-id strings
# (target_id / tool_id), which the smoke worker would have to resolve
# via find_components first. The goal here is to exercise the multi-
# client server, not to test boolean ops; the work is "heavy" because
# create_component on a 1m cube is a slower handler than get_model_info.
HEAVY_WORKLOAD = [
    {"tool": "create_component",
     "args": {"name": "smoke_box_heavy_A", "type": "cube",
              "position": [0, 0, 0], "dimensions": [1000, 1000, 1000]}},
    {"tool": "create_component",
     "args": {"name": "smoke_box_heavy_B", "type": "cube",
              "position": [400, 400, 400], "dimensions": [800, 800, 800]}},
    {"tool": "get_model_info", "args": {}},
    {"tool": "delete_component", "args": {"name": "smoke_box_heavy_A"}},
    {"tool": "delete_component", "args": {"name": "smoke_box_heavy_B"}},
]


def spawn_worker(label: str, workload: list[dict]) -> subprocess.Popen:
    script = WORKER_SCRIPT % {
        "src_dir": str(PROJECT_ROOT / "src"),
        "workload": workload,
        "label": label,
    }
    return subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ},
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=2,
        help="number of concurrent workers (default: 2; max practical: 4)")
    args = parser.parse_args()

    workers = []
    for i in range(args.n):
        wl = LIGHT_WORKLOAD if i == 0 else HEAVY_WORKLOAD
        workers.append((f"w{i}", spawn_worker(f"w{i}", wl), wl))

    t_start = time.monotonic()
    failures = []
    for label, proc, wl in workers:
        global_budget = WORKER_PER_OPERATION_BUDGET * len(wl)
        try:
            out, _ = proc.communicate(timeout=global_budget * 2)
        except subprocess.TimeoutExpired:
            proc.kill()
            failures.append(f"[{label}] EXCEEDED timeout {global_budget*2:.0f}s")
            continue
        rc = proc.returncode
        if rc != 0:
            failures.append(f"[{label}] EXIT {rc}\n{out}")
        else:
            print(out, end="")
    elapsed = time.monotonic() - t_start
    print(f"\nelapsed: {elapsed:.1f}s")

    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f)
        sys.exit(1)
    print("\nOK — all workers completed successfully.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify the script syntax compiles**

```bash
uv run python -c "import ast, pathlib; ast.parse(pathlib.Path('examples/smoke_multi_client.py').read_text())"
# Expected: no output (clean parse)
```

- [ ] **Step 3: Document a manual verification step**

This is **a manual step the human runs**, not part of the automated
suite. To verify end-to-end:

1. Start SketchUp 2026 with the new `.rbz` plugin installed.
2. Plugins → MCP Server → Start.
3. From a shell:
   ```bash
   uv run python examples/smoke_multi_client.py --n 2
   ```
4. Expected: both workers complete without error, total elapsed time
   roughly = sum of per-worker workload times divided by the
   serialisation factor (heavy worker dominates). Output lines from
   both workers interleave.

If the script fails:
- "ConnectionError" → the plugin isn't running or the wrong host/port.
- "IncompatibleVersionError" → Python and Ruby halves were not upgraded
  in lockstep; rebuild and reinstall the `.rbz`.
- One worker times out while the other proceeds → starvation; review
  `drain_one_client`'s iteration bound and `accept_pending_clients`
  loop placement.

- [ ] **Step 4: Commit**

```bash
git add examples/smoke_multi_client.py
git commit -m "test(python): live multi-client smoke (manual)

Spawns N subprocess workers, each opens its own SketchUpConnection,
runs a scripted workload (one light, one heavy). Asserts all complete
within budget × 2 without errors.

Not part of CI — manual sanity check before merging."
```

---

## Task 9: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Locate and edit the "Non-Obvious Constraints" section**

In `CLAUDE.md`, find the bullet that begins **"Ruby accepts a single TCP client at a time"** (it spans several lines, mentions `IDLE_DEADLINE_S = 300.0`, and explains the smoke-check workaround).

Replace it with:

```markdown
- **Ruby supports N concurrent TCP clients**: `core/server.rb` keeps
  `@clients` (sock → ClientState) and a global FIFO `@frame_queue`.
  Each timer tick: accept pending connections, drain reads from every
  client into per-client `FrameReader`, dispatch queued frames in
  arrival order. Operations are still serialised on the SketchUp UI
  thread (single-threaded Ruby API). Per-client errors close only the
  offending client; other clients keep running. **Logical races between
  clients on the model are the user's responsibility** — the server
  does no locking. Half-open sockets are detected via `SO_KEEPALIVE`
  (OS default ~2h).
```

- [ ] **Step 2: Rewrite the "Version handshake" paragraph**

In `CLAUDE.md`, find the long paragraph beginning **"Version handshake:
every JSON-RPC request carries `client_version`…"** in the Non-Obvious
Constraints section.

Replace it with:

```markdown
- **Version handshake (one-time on connect)**: every TCP connection MUST
  begin with a JSON-RPC `hello` request carrying
  `params.client_version`. The server validates against
  `core/compat.rb`'s `MIN_PYTHON`..`MAX_PYTHON` range and replies with
  `{server_version, client_id}` in `result`. Mismatches return JSON-RPC
  error `-32001` (`IncompatibleVersionError` on the Python side) and
  the server closes the socket. After a successful handshake, regular
  `tools/call` requests carry no `client_version` field and responses
  carry no `server_version` field. Compatibility ranges live in
  `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb`.
  `get_version` remains a regular tool returning the verdict payload.
```

- [ ] **Step 3: Remove the dormant `prompts/list` note**

In the **"MCP Prompts"** section near the bottom of `CLAUDE.md`, find
the `> Note:` block that mentions the dormant `prompts/list → []`
branch in `dispatch.rb`. Delete the entire note block — the branch is
gone.

- [ ] **Step 4: Sanity-check no stale `IDLE_DEADLINE_S` references remain**

```bash
grep -nF "IDLE_DEADLINE_S" CLAUDE.md
# Expected: no matches
```

If a match remains, delete the line. Same for `accept_one_client` (no
longer exists):

```bash
grep -nE "accept_one_client|single.*@client|first client wins" CLAUDE.md
# Expected: no matches
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for multi-client server and one-time handshake

- Replace 'single TCP client' constraint with the multi-client variant.
- Rewrite Version handshake paragraph for one-time on-connect semantics.
- Drop the dormant prompts/list note (branch removed).
- Drop stale IDLE_DEADLINE_S / accept_one_client mentions."
```

---

## Task 10: Release notes and final verification

**Files:**
- Modify: `docs/release.md` (append breaking-change note)
- Verify: full Ruby + Python suites, smoke (manual)

- [ ] **Step 1: Append release note**

Open `docs/release.md`. Find the appropriate location (top of the file
if it follows reverse-chronological order; otherwise the "Unreleased"
section). Add:

```markdown
## Breaking changes (next release)

- **Wire protocol: one-time handshake on connect.** Every TCP connection
  must now begin with a JSON-RPC `hello` request carrying
  `params.client_version`; the server replies with `server_version` and
  `client_id`. Per-request `client_version` / per-response
  `server_version` envelopes are **removed**. Old Python clients
  (`sketchup-mcp2 <= 0.1.x`) fail the handshake against this server and
  must be upgraded in lockstep with the `.rbz`.
- **Multi-client support.** The Ruby plugin now accepts N concurrent TCP
  clients; the previous "first client wins, rest time out" behavior is
  gone. The `restart plugin between smoke checks` workaround is no
  longer necessary.
```

If `docs/release.md` doesn't have any "next release" section yet, place
the note at the top of the file under a new heading.

- [ ] **Step 2: Full Ruby test suite**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: 0 failures, 0 errors. Approximate count: ~ 212 runs.
```

- [ ] **Step 3: Full Python test suite**

```bash
uv run pytest tests/ -q 2>&1 | tail -3
# Expected: 0 failures. Approximate count: ~ 110-115 passed (lower than
# pre-change because obsolete version-handshake-per-request tests were
# deleted in Task 6).
```

- [ ] **Step 4: Quick syntax / load check for the smoke script**

```bash
uv run python -c "import ast, pathlib; ast.parse(pathlib.Path('examples/smoke_multi_client.py').read_text())"
# Expected: clean
```

- [ ] **Step 5: Build the `.rbz` (sanity check that the Ruby reorg loads)**

```bash
cd su_mcp && ruby package.rb && cd ..
# Expected: prints the path to the .rbz; exit 0.
```

- [ ] **Step 6: Manual live smoke (HUMAN ACTION REQUIRED)**

This step is **for the human operator** — it requires a real SketchUp
2026 instance with the rebuilt `.rbz` installed and the MCP server
started. Capture the result.

1. Install the freshly-built `.rbz` (Window → Extension Manager →
   Install) and restart SketchUp.
2. Plugins → MCP Server → Start.
3. From a shell:
   ```bash
   uv run python examples/smoke_check.py
   ```
   Expected: 22 steps green.
4. Then:
   ```bash
   uv run python examples/smoke_multi_client.py --n 2
   ```
   Expected: both workers complete successfully; no `IncompatibleVersionError`,
   no `ConnectionError`, no starvation timeout.

If either fails, **do not commit the release note** — investigate and
fix first.

- [ ] **Step 7: Commit release note**

(Only after step 6 is green.)

```bash
git add docs/release.md
git commit -m "docs: release notes for multi-client + one-time-handshake breaking change"
```

- [ ] **Step 8: Final git log review**

```bash
git log --oneline feature/viewport-screenshot-and-prompt..HEAD
# Expected: ~ 10 commits, one per task, with the design + plan docs at
# the top. (Design + plan will be removed in the PR-finishing step,
# per global CLAUDE.md rule — but that is a separate step done with
# the superpowers:finishing-a-development-branch skill, not part of
# this plan.)
```

---

## Review Iteration 1 — Applied Auto-Fixes (overrides above)

The following deltas were applied after external review (iter-1). Where they conflict with code blocks above, **these instructions win** — the executor should integrate them into the corresponding Task before running.

### A. Task 1 — `ClientState` adds `close_after_response` accessor

In `su_mcp/su_mcp/core/client_state.rb`, change `attr_accessor` to:

```ruby
attr_accessor :handshaked, :client_version, :close_after_response
```

And `initialize`:

```ruby
def initialize(id, sock)
  @id                   = id
  @sock                 = sock
  @reader               = Framing::FrameReader.new
  @label                = "##{id}[#{peer_label(sock)}]"
  @handshaked           = false
  @client_version       = nil
  @close_after_response = false
end
```

Add a corresponding test in `test/test_client_state.rb`:

```ruby
def test_close_after_response_starts_false_and_is_mutable
  state = SU_MCP::Core::ClientState.new(0, FakeSockForState.new)
  refute state.close_after_response
  state.close_after_response = true
  assert state.close_after_response
end
```

Update Step 5 expected count to **7 runs, 9 assertions**, Step 6 full-suite count by +1.

### B. Task 4 — `accept_pending_clients` hardening (CONCERN-1, CONCERN-2)

Replace the Step-4 `accept_pending_clients` body in `server.rb` with:

```ruby
ACCEPT_ABORTED_MAX = 10

def accept_pending_clients
  aborted = 0
  loop do
    begin
      sock = @server.accept_nonblock
    rescue IO::WaitReadable
      return
    rescue Errno::ECONNABORTED
      aborted += 1
      return if aborted >= ACCEPT_ABORTED_MAX
      next
    end
    begin
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
    rescue StandardError => e
      # accept succeeded but the socket is unusable. Close it; do NOT
      # register — registered-or-closed is the invariant we keep.
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

This subsumes Task 7's `SO_KEEPALIVE` setsockopt (already present here). Task 7's test of "SO_KEEPALIVE is set on accept" stays valid. **Add** in Task 4 a test for the setsockopt-leak case:

```ruby
def test_setsockopt_failure_closes_sock_and_skips_registration
  sock = FakeSocket.new
  def sock.setsockopt(*_); raise StandardError, "synthetic setsockopt"; end
  fs = FakeServer.new([sock])
  srv = run_one_tick(fs)
  assert sock.closed?, "sock with failing setsockopt must be closed"
  assert_equal 0, srv.instance_variable_get(:@clients).size
end
```

### C. Task 4 — `test/support/frame_helpers.rb` (SUGGESTION-2)

Before writing `test_server_multi_client.rb`, create `test/support/frame_helpers.rb`:

```ruby
# test/support/frame_helpers.rb — shared length-prefix frame encode/decode.
require "json"

module FrameHelpers
  def fr(obj)
    body = JSON.generate(obj)
    [body.bytesize].pack("N") + body
  end

  def all_frames(bytes)
    bytes = bytes.dup.force_encoding(Encoding::ASCII_8BIT)
    out = []
    until bytes.empty?
      len = bytes.byteslice(0, 4).unpack1("N")
      out << JSON.parse(bytes.byteslice(4, len))
      bytes = bytes.byteslice(4 + len..-1) || ""
    end
    out
  end
end
```

Drop the module-level `def fr` / `def all_frames` from both `test_server_multi_client.rb` and `test_server_handshake.rb`; instead inside each test class `include FrameHelpers` (after `require_relative "support/frame_helpers"`).

### D. Task 4 / Task 5 — restore `io_select_writable?` in test teardown (SUGGESTION-3)

The monkey-patch via `class_eval` is process-global. Add to **both** `TestServerMultiClient` and `TestServerHandshake`:

```ruby
def setup
  @orig_io_select_writable = SU_MCP::Core::Server.instance_method(:io_select_writable?)
  # ... existing setup ...
end

def teardown
  SU_MCP::Core::Server.send(:define_method, :io_select_writable?, @orig_io_select_writable)
end
```

### E. Task 4 — additional test coverage (CONCERN-6, CONCERN-7, CONCERN-8, CONCERN-10)

Append to `test_server_multi_client.rb`:

```ruby
# CONCERN-7 — framing oversize MUST deliver -32600 envelope before close
def test_framing_oversize_writes_envelope_before_close
  over = SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1
  bad_frame = [over].pack("N")
  a = FakeSocket.new(read_chunks: [bad_frame])
  fs = FakeServer.new([a])
  run_one_tick(fs)
  frames = all_frames(a.written)
  assert_equal 1, frames.size
  assert_equal(-32600, frames[0]["error"]["code"])
  assert a.closed?
end

# CONCERN-8 — partial-frame EOF (header only, no body) closes cleanly
def test_partial_frame_eof_closes_client
  header_only = [100].pack("N")  # promise 100 bytes, deliver 0
  a = FakeSocket.new(read_chunks: [header_only])
  a.push_eof
  fs = FakeServer.new([a])
  run_one_tick(fs)
  assert a.closed?
end

# CONCERN-6 — frame split across two ticks dispatches correctly
def test_frame_split_across_ticks_dispatches_after_completion
  req = fr("jsonrpc" => "2.0", "method" => "tools/call",
           "params" => { "name" => "get_version", "arguments" => {} },
           "id" => 1)
  prefix = req.byteslice(0, 10)
  suffix = req.byteslice(10..-1)
  a = FakeSocket.new(read_chunks: [prefix])
  fs = FakeServer.new([a])
  srv = SU_MCP::Core::Server.new
  srv.instance_variable_set(:@server, fs)
  srv.instance_variable_set(:@running, true)
  SU_MCP::Core::Server.class_eval do
    def io_select_writable?(_sock); true; end
  end
  srv.send(:on_timer_tick)
  assert_equal "", a.written, "no response after partial frame"
  a.push_read(suffix)
  srv.send(:on_timer_tick)
  frames = all_frames(a.written)
  assert_equal [1], frames.map { |f| f["id"] }
end
```

For CONCERN-10 (expand `test_server_level_error_in_tick_does_not_reset_clients`): the test already exists; CONCERN-2's new test (above in §B) covers the post-accept setsockopt path so it complements rather than replaces it.

### F. Task 5 — handshake test additions (CONCERN-9, CONCERN-11)

Modify `test_post_handshake_response_has_no_server_version_field` to also positively assert the handshake reply carries `server_version`:

```ruby
def test_handshake_reply_carries_server_version_post_handshake_does_not
  # ... unchanged setup ...
  frames = all_frames(sock.written)
  assert_equal SU_MCP::Core::Compat::SERVER_VERSION,
    frames[0]["result"]["server_version"],
    "handshake reply must carry server_version"
  refute frames[1].key?("server_version"),
    "post-handshake response must not carry server_version"
end
```

Add a new test for `close_after_response` + write-failure path (CONCERN-11):

```ruby
def test_handshake_rejection_with_epipe_still_closes_client
  bad = hello_frame(version: "0.0.0", id: 0)
  sock = FakeSocket.new(read_chunks: [bad])
  fs = FakeServer.new([sock])
  srv = SU_MCP::Core::Server.new
  srv.instance_variable_set(:@server, fs)
  srv.instance_variable_set(:@running, true)
  # Force write to raise EPIPE — rescue path must still close the client.
  SU_MCP::Core::Server.class_eval do
    def io_select_writable?(_sock); true; end
  end
  sock.define_singleton_method(:write) { |_| raise Errno::EPIPE, "synthetic" }
  srv.send(:on_timer_tick)
  assert sock.closed?, "rejected client must be closed even when write raises EPIPE"
end
```

### G. Task 6 — additional Python tests (CRITICAL-6, CONCERN-13, SUGGESTION-7)

Append to `tests/test_connection.py`:

```python
@pytest.mark.asyncio
async def test_stale_socket_retry_redoes_handshake():
    """After a stale socket is detected, retry must re-handshake on the new socket."""
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 1,
    }).encode("utf-8"))
    # First connection: handshake + closes immediately (stale).
    # Second connection (after retry): handshake + tool reply.
    # NB: FakeServer must serve two clients sequentially — see fixture below
    #     for the multi-connection variant.
    async with FakeServerMulti([
        [hello_success(compat.CLIENT_VERSION)],          # client 1: handshake only, then close
        [hello_success(compat.CLIENT_VERSION), tool_reply],  # client 2: handshake + reply
    ]) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        # Simulate stale-socket detection on the retry path.
        # Send a no-op tool and rely on the FakeServerMulti closing
        # the first connection between hello and tool reply.
        result = await conn.send_command("some_tool", {})
        assert result["isError"] is False
        await conn.disconnect()


@pytest.mark.asyncio
async def test_handshake_timeout_raises_sketchup_error():
    """Ruby that accepts TCP but never replies must surface as timeout, not a hang."""
    async with FakeServer([]) as fs:   # no script — server never writes
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=0.5)
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
        assert "timed out" in str(ei.value).lower()
```

For `test_connect_sends_hello_first_with_client_version` (CONCERN-13): replace the hardcoded `await asyncio.sleep(0.05)` with explicit synchronization. Recommended pattern: set `asyncio.Event` in `FakeServer._handle` after `_received` reaches the expected length, and `await event.wait()` in the test. (If implementation complexity is undesirable, use a `for _ in range(10): if len(fs.received) >= expected: break; await asyncio.sleep(0.01)` busy-loop with explicit upper bound — at least it's bounded.)

For `test_send_once_does_not_require_server_version_in_response` (SUGGESTION-7): replace tool name `"get_version"` with `"some_tool"` — it removes the implication that the test is about `get_version`'s version-checking semantics. The test is purely about envelope shape.

Add the multi-connection FakeServer helper at the top of the test module:

```python
class FakeServerMulti:
    """Like FakeServer but serves each new TCP connection with its own script."""

    def __init__(self, scripts: list[list[bytes]]):
        self._scripts = list(scripts)
        self._idx = 0
        self._server: asyncio.base_events.Server | None = None
        self.host = "127.0.0.1"
        self.port = 0

    async def __aenter__(self):
        self._server = await asyncio.start_server(
            self._handle, host=self.host, port=0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, reader, writer):
        if self._idx >= len(self._scripts):
            writer.close()
            return
        script = self._scripts[self._idx]
        self._idx += 1
        for chunk in script:
            writer.write(chunk)
            await writer.drain()
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
```

### H. Task 6 — update `src/sketchup_mcp/tools.py` (CONCERN-4)

After Step 5 (compat.py wording), add:

> **Step 5b: Update `get_version` description in `src/sketchup_mcp/tools.py`**
>
> Find the `get_version` tool definition and its docstring (around lines 455 and 482). Remove the "only diagnostic bypass" / "bypass" phrasing. The tool is now an ordinary `tools/call` that returns the server's version verdict payload. Adjust wording to: "Returns the server version and Python↔Ruby compatibility verdict. Useful as a runtime sanity probe."

### I. Task 4 — comment on FIFO guarantee (SUGGESTION-4)

In the new `server.rb`, add a comment block above `drain_reads_all_clients`:

```ruby
# Global FIFO: `@clients` is a Hash, whose iteration order in Ruby 1.9+
# is the *insertion order* (i.e. the order in which TCP accept assigned
# each client). For each client we drain reads in that order, appending
# decoded frames to `@frame_queue` as they become available. The
# resulting dispatch order is therefore "FIFO by (accept-order, then
# decoded-frame arrival within that client)". This is deliberate — see
# design §5.3 / §13.1 for the rationale (round-robin reads were
# considered and explicitly rejected).
def drain_reads_all_clients
  ...
end
```

### J. Test count baseline adjustments

After all the additions above:
- Task 1: 7 runs (was 6)
- Task 4: +5 new tests (setsockopt-leak, framing-envelope-before-close, partial-frame-eof, multi-tick frame split, plus the existing 10) ≈ 15 runs
- Task 5: +1 new test (handshake_rejection_with_epipe) ≈ 10 runs
- Task 6: +2 Python tests (stale_socket_retry, handshake_timeout) ≈ 8 added

Cumulative Ruby total at end of Task 7: ~ 220 runs (vs the original plan's ~ 212). Cumulative Python at end of Task 6: ~ 113 passed (vs original ~ 110-115). Adjust per-task expected counts up accordingly.

---

## Self-Review Notes

Coverage check against design sections:

- §4 (high-level structure): Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 collectively touch every file listed. ✓
- §5.1 (ClientState): Task 1. ✓
- §5.2 (Server fields): Task 4. ✓
- §5.3 (tick algorithm — accept, drain, queue, process): Task 4. ✓
- §5.4 (close_client): Task 4. ✓
- §6 (handshake protocol): Task 5 (Ruby) + Task 6 (Python). ✓
- §7 (error isolation table): Task 4 + Task 5. ✓
- §8 (logging): Task 2 (Logger API) + Tasks 4, 5 (call sites). ✓
- §9 (configuration): Task 4 (drop IDLE) + Task 7 (SO_KEEPALIVE). ✓
- §10 (testing): Tasks 1, 2, 3, 4, 5, 6, 8 — every test scenario in
  the spec has a corresponding task step. ✓
- §11 (docs): Task 9 (CLAUDE.md) + Task 10 (release.md). ✓
- §13 (risks): no code, no task — risks are documented in the spec,
  not implemented. Plan covers all mitigations that were in scope. ✓

Placeholder scan: no TBD / TODO / "appropriate" / "similar to" left in
the plan body. Every step has concrete code or commands.

Type-consistency check: function and constant names used across tasks
match (`ClientState.handshaked`, `Server#close_client`, `_handshake`,
`HELLO` test helper, `FakeSocket` / `FakeServer` helpers, etc.).

# Block C (socket authentication and transport) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every TCP client must prove it knows a token the plugin generated before any tool runs, the transport resists floods and malformed input, and the docs say how to set the token, on branch `fix/p4-socket-auth`.

**Architecture:**
- **Token and proofs.** The plugin keeps a 32-byte token in SketchUp's preferences. A new `Core::Auth` computes HMAC-SHA256 proofs over two nonces. The handshake grows from one round trip (`hello`) to two (`hello`, then `auth`). Each side proves it knows the token, and the token itself never crosses the wire.
- **Python side.** A new `sketchup_mcp/auth.py` mirrors `Core::Auth`. `SketchUpConnection` refuses to open a socket without a well-formed token.
- **Hardening.** It lands in the existing server loop: framing caps, per-client caps, write deadlines, error encoding, logging. The Settings dialog shows the token, with Copy and Regenerate, and one loopback check feeds both the bind warning and the dialog.

**Tech Stack:** Ruby (SketchUp 2024–2027: Ruby 3.2 and 3.4; stdlib `openssl`, `securerandom`, `socket`) with minitest; Python ≥ 3.10 (`hmac`, `hashlib`, `secrets`), FastMCP (`mcp>=1.30,<2`), pytest.

**Spec:** `docs/superpowers/specs/2026-11-20-release-0.5.0-design.md`. The relevant sections are:
- §2 (goals);
- §4 (process; live checks need an installed build);
- §7 (block C);
- §9 (decisions 6, 9, 10 and the calls listed after them);
- §10 (left to the builder);
- §11 (not in 0.5.0: M-20, the rest of M-27 and M-29).

## Global Constraints

- **Versions.** No version bump and no floor change on this branch. `SERVER_VERSION`, `MIN_PYTHON`, `MIN_RUBY` and the package version stay `0.4.0`; the release PR raises them (spec §8).
- **The token.**
  - It is 32 random bytes written as 64 lowercase hex characters, stored in preference section `MCPforSketchUp` under key `auth_token`.
  - It is never logged, never put in an error message or a response, and never sent over the wire.
  - The client reads it from `SKETCHUP_MCP_TOKEN`.
- **Proofs.** `HMAC-SHA256`, with the token's 64 ASCII characters as the key. The message is the label followed by `client_nonce` and `server_nonce`, all as ASCII hex with no separator. Labels: `sketchup-mcp/1/server`, `sketchup-mcp/1/client`. Proofs are lowercase hex. Nonces are 32 random bytes as 64 lowercase hex characters.
- **Test vector**, pinned in both languages (computed with Ruby `OpenSSL::HMAC` and Python `hmac`, and they agree). Token `"0123456789abcdef" * 4`, client nonce `"a" * 64`, server nonce `"b" * 64`:
  - server proof `a1069e0a855573049322f60ceb171ea5e84780060a85dbd060bcbbec96df272d`;
  - client proof `c968a257091ddea88a25001b219ab21a1609e2d5991b92adb3445c5bfdc7e279`.
- **Error codes.**
  - `-32001`: version; also a client or plugin that predates authentication.
  - `-32003`: authentication failed.
  - `-32600`: protocol.
  - `-32602`: bad params.
  - `-32603`: internal.
- **Wording.** User-facing texts name the menu `Extensions → MCP Server → …`. The API call `UI.menu("Plugins")` stays (M-23).
- **Live checks.** Hot reload does not cover `core/` or `ui/`; never hot-reload `ui/settings_dialog.rb`. Live checks need a plugin build installed in SketchUp (Task 9).
- **This session's MCP server runs from the checkout.** Once Task 5 lands, it speaks the new handshake and cannot talk to the installed 0.4.0 plugin until Task 9 installs the new build. That is expected (spec §4). Every commit keeps `python -m sketchup_mcp` importable.
- **Code and docs.**
  - No gem in the plugin.
  - Never run an auto-formatter over handlers or tests.
  - Comments follow their surroundings (this codebase mixes Russian and English); docs and docstrings are English; commits are Conventional Commits in English.
  - Commit only the files a task names, plus test files whose requires or fakes the change forces (name them in the report). Never commit `docs/superpowers/plans/*-prompt.md`, `full-review/` or `.venv.broken-task8/`.
  - After every task, `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q` are green, and so is `SKETCHUP_MCP_CONTRACT=1 uv run --locked pytest tests/test_contract_wire.py -q` from Task 6 on.
- **Test fakes.** Under `ruby test/run_all.rb` every test file loads into one process, so stubs of SketchUp and `UI` are guarded with `unless defined?`. Module functions are stubbed with `SingletonStubs` (Ruby) or `monkeypatch` (Python), never by reopening a class.
- **Nonces in tests.** Tests stub the nonce sources to the vector's values: `Core::Auth.nonce` returns `"b" * 64`, and `sketchup_mcp.auth.new_nonce` returns `"a" * 64`. Handshakes are then deterministic.
- **Rulings made in this plan.** The user can overrule any of them.
  1. A `hello` without `client_nonce` comes from a client that predates authentication: `-32001` with the upgrade hint, not an authentication error. The floors are still 0.4.0 on this branch, and spec §7.2 wants an old client to hear "upgrade".
  2. A `hello` reply without `server_nonce` and `server_proof` comes from a plugin that predates authentication: `IncompatibleVersionError` with the install hint.
  3. The client checks the token's form before connecting (64 lowercase hex characters after stripping whitespace). A malformed token answers like a missing one, naming its length, and opens no socket.
  4. `AuthenticationError` reaches the MCP client verbatim, with no `[code]` prefix and no tool/params tail, like the eval-gate message: the user must act on it.
  5. Both handshake requests use JSON-RPC id `0`. The handshake is strictly sequential, and `tools/call` ids are unchanged.
  6. In `auth`, a `client_proof` that is not a string is `-32602`; a string that does not match, of any length, is `-32003`.
  7. Rejected connections log one line per tick with their count. A client may have at most 32 frames queued; at most 16 connections are accepted per tick.
  8. Strict arguments allow the Ruby-only arguments the handlers read today: `segments` on `create_component`, `edge_indices` on `chamfer_edges` and `fillet_edges`, and `width` and `height` on `export` / `export_scene`. The contract test pins them.
  9. Log escaping covers every byte `0x00–0x1F` and `0x7F`: `\n`, `\r`, `\t`, others `\xNN`.
  10. The loopback check resolves names with `Addrinfo.getaddrinfo`. A host is loopback only when every address it resolves to is loopback; one that does not resolve counts as not loopback and is warned about.
  11. The dialog checks the typed host through a Ruby callback debounced 300 ms (JavaScript cannot resolve names).
  12. The token is created when the plugin loads (`Config.load_token!`, called from `main.rb`).
      - If saving it fails, the token stays for the session and a WARN is logged.
      - If Regenerate cannot save the new token, it keeps the old one and reports the error.
      - Closing the eval gate is saved first and never rolled back (M-31). Opening it is still saved last.
  13. The eager connect at startup is bounded by 5 s, independent of `SKETCHUP_MCP_TIMEOUT`. The lazy connect on the first tool call keeps the full timeout.

## Review Focus

1. **A client that stops after `hello`, or sends a tool call instead of `auth`.** It is never handshaked: the call is refused and the socket closed, and a silent client is closed at the 30 s pre-handshake deadline. Tests: Task 2 `test_tool_call_after_hello_is_refused`, `test_hello_without_auth_is_closed_at_the_deadline`.
2. **A `client_proof` of the wrong length or not hex.** `OpenSSL.fixed_length_secure_compare` raises on unequal lengths; the server must answer `-32003` and never crash. Tests: Task 1 `test_secure_equal_is_false_for_different_lengths`, Task 2 `test_short_client_proof_fails_authentication`.
3. **A token pasted into `.mcp.json` with spaces or a trailing newline, or a garbled one.** Whitespace is stripped; a garbled token gets the instruction and no connection. Tests: Task 5 `test_token_is_stripped_of_whitespace`, `test_malformed_token_answers_without_connecting`.
4. **Regenerate while a client has a frame queued or a response half-written.** That client is closed, its queued frame is dropped, nothing is written to a closed socket, and other clients are unaffected. Test: Task 7 `test_close_all_clients_drops_their_queued_frames`.
5. **A request nested past JSON's depth limit after the handshake, and a NaN argument.** The first gets an error response, not a hang; the second is refused locally with `-32602`. Tests: Task 3 `test_nesting_error_while_encoding_answers_with_an_error`, Task 5 `test_non_finite_argument_is_refused_before_sending`.

---

### Task 1: The token and the proofs, Ruby side (M-06)

**Files:**
- Create: `mcp_for_sketchup/mcp_for_sketchup/core/auth.rb`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/config.rb`, `mcp_for_sketchup/mcp_for_sketchup/main.rb` (LOAD_ORDER: `core/auth` after `core/compat`; call `Config.load_token!` right after `Config.load_from_defaults!`)
- Test: `test/test_auth.rb` (new), `test/test_config.rb`, `test/support/auth_vectors.rb` (new)

**Interfaces:**
- Produces:
  - `Core::Auth.generate_token -> String` and `Core::Auth.nonce -> String`: 64 lowercase hex characters each, from `SecureRandom.hex(32)`.
  - `Core::Auth.hex64?(value) -> bool`: true only for a String matching `/\A[0-9a-f]{64}\z/`.
  - `Core::Auth.proof(token, role, client_nonce, server_nonce) -> String`: `role` is `"server"` or `"client"`; the label is `"sketchup-mcp/1/#{role}"`.
  - `Core::Auth.secure_equal?(a, b) -> bool`: false unless both are Strings of the same bytesize; otherwise `OpenSSL.fixed_length_secure_compare`.
  - `Config.token` (accessor).
  - `Config.load_token!(store = Sketchup) -> String`.
  - `Config.regenerate_token!(store = Sketchup) -> String`.
  - `TOKEN_KEY = "auth_token"`.
  - `test/support/auth_vectors.rb`: `module AuthVectors` with `TOKEN`, `CLIENT_NONCE`, `SERVER_NONCE`, `SERVER_PROOF`, `CLIENT_PROOF`, the values from Global Constraints.

- [ ] **Step 1: Write the failing tests**

`test/test_auth.rb`:
- `test_proofs_match_the_cross_language_vector`: `Auth.proof(TOKEN, "server", CLIENT_NONCE, SERVER_NONCE) == SERVER_PROOF`, and the same with `"client"` gives `CLIENT_PROOF`.
- `test_generated_token_and_nonce_are_64_hex`: both match `/\A[0-9a-f]{64}\z/`, and two calls differ.
- `test_hex64_rejects_other_shapes`: false for `nil`, `"A" * 64`, `"a" * 63`, `"a" * 65`, `"g" * 64` and `64` (an Integer).
- `test_secure_equal_is_false_for_different_lengths`: `secure_equal?("ab", "abc")` is false and raises nothing; `secure_equal?(nil, "a")` is false; `secure_equal?(SERVER_PROOF, SERVER_PROOF.dup)` is true.

`test/test_config.rb`, with a recording store answering `read_default`/`write_default`:
- `test_load_token_creates_and_saves_a_token`: with nothing stored, `load_token!` returns 64 hex characters, `Config.token` equals it, and the store recorded `["MCPforSketchUp", "auth_token", token]`.
- `test_load_token_keeps_a_valid_stored_token`: a stored `TOKEN` comes back unchanged, and nothing is written.
- `test_load_token_replaces_a_malformed_stored_token`: a stored `"x" * 10` is replaced by a new 64-hex token, which is saved. The WARN line names the key but not either value.
- `test_load_token_keeps_the_token_when_saving_fails`: `write_default` returns false, so a token is still set for the session and a WARN says it could not be saved.
- `test_regenerate_token_saves_a_new_token`: the new token differs from the old one and is saved.
- `test_regenerate_token_keeps_the_old_token_when_saving_fails`: `write_default` returns false, so it raises, and `Config.token` is the old token.

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_auth.rb; ruby test/test_config.rb`
Expected: errors on `MCPforSketchUp::Core::Auth` (uninitialized constant) and `load_token!` (undefined method).

- [ ] **Step 3: Implement `core/auth.rb` and the token in `Config`**

`core/auth.rb` requires `openssl` and `securerandom`. `proof` is `OpenSSL::HMAC.hexdigest("SHA256", token, label + client_nonce + server_nonce)`.

In `Config`, `load_token!` reads `auth_token`. A value that is not `hex64?` is replaced by `Auth.generate_token` and saved. A failed save logs WARN `config: could not save the MCP token; a new one will be made at the next start` and keeps the token. Log lines never contain the token. Guard `Core::Logger` with `defined?`, as `warn_invalid_pref` does.

- [ ] **Step 4: Run them to verify they pass, then the suite**

Run: `ruby test/test_auth.rb && ruby test/test_config.rb && ruby test/run_all.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/auth.rb mcp_for_sketchup/mcp_for_sketchup/core/config.rb mcp_for_sketchup/mcp_for_sketchup/main.rb test/test_auth.rb test/test_config.rb test/support/auth_vectors.rb
git commit -m "feat: generate and keep an MCP token in the plugin"
```

---

### Task 2: The two-step handshake on the server (M-06, M-15 part, M-21 Ruby part, M-31 part)

**Files:**
- Modify:
  - `mcp_for_sketchup/mcp_for_sketchup/core/server.rb`
  - `core/client_state.rb`
  - `core/framing.rb`
  - `core/compat.rb`
  - `core/errors.rb`
  - `core/logger.rb`
  - `core/config.rb` (`PRE_HANDSHAKE_MAX_MESSAGE_SIZE = 4 * 1024`)
  - `test/contract/echo_server.rb`: load `core/auth`, and set `config.token = ENV.fetch("SKETCHUP_MCP_TOKEN")`. Update its comment: rejected handshakes now log at WARN. The Python side of the contract test follows in Task 6, so until then the contract job is red; it is not in the per-task gate before Task 6.
- Test:
  - `test/test_server_handshake.rb` (rewrite to the new flow);
  - `test/test_server_multi_client.rb`, `test/test_client_state.rb`, `test/test_state_machine.rb` (move to the helper);
  - `test/test_logger.rb`, `test/test_framing.rb`, `test/test_errors.rb`;
  - `test/support/frame_helpers.rb`.

**Interfaces:**
- Consumes: Task 1's `Auth.*`, `Config.token`, `AuthVectors`.
- Produces:
  - `ClientState#client_nonce`, `#server_nonce` (accessors, nil until `hello`).
  - `FrameReader.new(max_frame: Config::MAX_MESSAGE_SIZE)` and `FrameReader#max_frame=`. `ClientState` builds its reader with `PRE_HANDSHAKE_MAX_MESSAGE_SIZE`, and the server lifts it to `MAX_MESSAGE_SIZE` when `auth` succeeds.
  - `Errors.exception_to_data(exception, tool, params, backtrace: true)`: with `backtrace: false` the `"backtrace"` key is left out.
  - `Logger::WARN_STATUSES = %w[handshake_rejected auth_failed write_timeout pre_handshake_timeout pending_write_overflow]`; `log_tool` logs those statuses at WARN and every other status at INFO.
  - `Compat.msg_python_unauthenticated(client_version) -> String`.
  - In `FrameHelpers`: `hello_frame(id: 0, version: MIN_PYTHON, client_nonce: AuthVectors::CLIENT_NONCE)`, `auth_frame(id: 0, client_proof: AuthVectors::CLIENT_PROOF)` and `handshake_frames` (both, in one string). Tests that use them stub `Core::Auth.nonce` to return `AuthVectors::SERVER_NONCE` and set `Config.token = AuthVectors::TOKEN`.

The exchange (spec §7.2):

| Step | Client sends | Server answers |
|---|---|---|
| 1 | `hello {client_version, client_nonce}` | version check first (`-32001`). No `client_nonce` → `-32001` with `msg_python_unauthenticated`. Not `hex64?` → `-32602 "hello requires params.client_nonce (64 lowercase hex characters)"`. Otherwise store both nonces and answer `result {server_version, server_nonce, server_proof}`. |
| 2 | `auth {client_proof}` | Anything but `auth` → `-32600 "expected 'auth' after 'hello' (got: <method.inspect>)"`. A `client_proof` that is not a String → `-32602 "auth requires params.client_proof (string)"`. No match → `-32003 "authentication failed"`, logged as status `auth_failed` with the client label only. A match → `handshaked = true`, lift the frame cap, answer `result {client_id}`, log `handshake_ok`. |

Every refusal before the handshake completes closes the socket after the response, as `reject_handshake` does today. Its data carries no backtrace. A missing or malformed `Config.token` makes `hello` answer `-32603 "the plugin has no token; restart SketchUp to create one"`.

`msg_python_unauthenticated(cv)` is: `"sketchup-mcp2 v#{cv} pre-dates socket authentication, which SketchUp plugin v#{SERVER_VERSION} requires. Handshake rejected. #{UPGRADE_CLIENT_HINT} Call `get_version` to inspect handshake state."`

A frame over the cap before the handshake is refused at its header by `FrameReader#validate_length!` with `-32600 "message too large before the handshake: <len> bytes (cap 4096)"`. The existing close-after-drain path handles it.

- [ ] **Step 1: Write the failing tests**

Expectations of the new `test_server_handshake.rb`; each test runs ticks over `FakeSocket`/`FakeServer`:
- `test_hello_answers_with_the_server_nonce_and_proof`: `result` is `{server_version, server_nonce: "b"*64, server_proof: SERVER_PROOF}`, with no `client_id`, and the state is not handshaked.
- `test_handshake_completes_with_the_right_client_proof`: the second frame's `result` has `client_id`, the state is handshaked, and `state.reader.max_frame == Config::MAX_MESSAGE_SIZE`.
- `test_wrong_client_proof_fails_authentication`: `-32003`, message `"authentication failed"`, the socket closed after the drain, a WARN line with `status=auth_failed`, and neither the proof nor the token in any log line.
- `test_short_client_proof_fails_authentication`: proof `"c968"` gives `-32003`, and nothing is raised.
- `test_non_string_client_proof_is_refused`: `{"client_proof" => 5}` gives `-32602`.
- `test_tool_call_after_hello_is_refused`: `tools/call` after `hello` gives `-32600` naming `'auth'`, and the socket closes.
- `test_auth_before_hello_is_refused`: the existing "first method must be 'hello'" message.
- `test_hello_without_client_nonce_is_an_old_client`: `-32001`, and the message includes `"pre-dates socket authentication"` and `UPGRADE_CLIENT_HINT`.
- `test_malformed_client_nonce_is_refused`: `"z"*64` gives `-32602`.
- `test_old_client_version_is_refused_before_the_nonce_is_read`: version `"0.0.1"` with no nonce gives the existing too-old `-32001` message.
- `test_rejections_before_the_handshake_carry_no_backtrace`: `data` has no `"backtrace"` key.
- `test_hello_without_auth_is_closed_at_the_deadline`: after `hello`, with `connected_at` moved back 31 s, the sweep closes the client with a WARN `pre_handshake_timeout`.
- `test_frame_over_4_kib_before_the_handshake_is_refused_at_its_header`: a header announcing 4097 bytes, with the body never sent, gives `-32600` with `"before the handshake"` and `"cap 4096"`.
- `test_large_frame_after_the_handshake_is_accepted`: a 5000-byte `tools/call` after `handshake_frames` reaches dispatch.
- `test_server_without_a_token_refuses_hello`: with `Config.token = nil`, `-32603` with `"no token"`.

Plus:
- `test_logger.rb` `test_warn_statuses_log_at_warn`: at `Config.log_level = "WARN"`, `log_tool("server", "auth_failed")` is emitted and `log_tool("server", "client_connected")` is not.
- `test_framing.rb` `test_max_frame_is_settable`.
- `test_errors.rb` `test_exception_to_data_can_leave_out_the_backtrace`.

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_server_handshake.rb`
Expected: failures on the missing `server_nonce` and the missing `-32003` path.

- [ ] **Step 3: Implement the exchange in `Server#handle_pre_handshake` and its helpers**

Keep `reject_handshake` as the one refusal path; give it a `tool` label (`"hello"` or `"auth"`) for its data.

- [ ] **Step 4: Move the other server tests to `handshake_frames`**

These files use `hello_frame` followed by tool calls and now need `handshake_frames`: `test_server_multi_client.rb`, `test_client_state.rb`, `test_state_machine.rb`. Responses gain one frame (the `auth` reply), so indexes into `all_frames` shift by one.

- [ ] **Step 5: Run the Ruby suite**

Run: `ruby test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/ test/contract/echo_server.rb test/test_server_handshake.rb test/test_server_multi_client.rb test/test_client_state.rb test/test_state_machine.rb test/test_logger.rb test/test_framing.rb test/test_errors.rb test/support/frame_helpers.rb
git commit -m "feat!: authenticate every client with a token challenge after hello"
```

---

### Task 3: Transport hardening in the server loop (M-15, M-13, M-14)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/server.rb`, `core/errors.rb`
- Test: `test/test_server_hardening.rb` (new), `test/test_errors.rb`

**Interfaces:**
- Consumes: Task 2's handshake helpers.
- Produces: `Server::PER_CLIENT_QUEUE_MAX = 32` and `Server::ACCEPTS_PER_TICK_MAX = 16`.

Behaviour:
- **Per-client queue cap.** `drain_one_client` reads nothing from a client whose `queued_frames >= PER_CLIENT_QUEUE_MAX`, and stops mid-drain once it reaches the cap. The overshoot is bounded by one `read_nonblock` chunk, as with `FRAME_QUEUE_SOFT_MAX`.
- **Accept cap.** `accept_pending_clients` accepts at most `ACCEPTS_PER_TICK_MAX` sockets per tick, registered or rejected. The rest wait in the kernel backlog.
- **Rejected connections.** Over `MAX_CLIENTS`, rejected sockets are counted, and one `client_rejected` line per tick gives `reason=max_clients limit=64 count=<n>`.
- **Write deadline (M-13).** It is checked only when a write makes no progress: in the `IO::WaitWritable` rescue and in the zero-bytes branch, through one helper, `close_if_write_stalled(state)`. It is no longer checked before trying.
- **JSON errors (M-14).** `encode_response_body` and `Errors.truncate_params` rescue `JSON::JSONError` (which covers `NestingError` and `GeneratorError`) and `Encoding::UndefinedConversionError`.

- [ ] **Step 1: Write the failing tests** (`test/test_server_hardening.rb`, ticks over fakes)

- `test_a_client_stops_being_read_at_its_queue_cap`: a handshaked client with 40 `tools/call` frames, one per `push_read` chunk, and the dispatch cap made 0 for the tick (stub `process_frame_queue`). After one drain, `queued_frames` is 32.
- `test_accepts_are_capped_per_tick`: a `FakeServer` with 20 pending sockets. After one tick 16 are registered; after the next, 20.
- `test_rejections_log_one_line_per_tick`: 64 clients registered and 5 more pending give exactly one `client_rejected` line containing `count=5`.
- `test_a_late_writable_socket_is_written_not_closed`: a pending write whose deadline is already past, on a socket that accepts the bytes now. The bytes are delivered, and the client stays open.
- `test_a_stalled_socket_past_its_deadline_is_closed`: `stub_write_pending` past the deadline closes the client with `write_timeout`, logged at WARN.
- `test_nesting_error_while_encoding_answers_with_an_error`: `encode_response_body` of a result nested 120 levels returns a JSON `-32603` envelope and does not raise.

In `test_errors.rb`, `test_truncate_params_survives_a_nesting_error`: params nested 120 levels give the `"_unserializable"` marker.

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_server_hardening.rb`
Expected: failures on the uncapped queue and accepts, five log lines instead of one, the late-writable client closed, and `JSON::NestingError` raised.

- [ ] **Step 3: Implement the five changes in `server.rb` and `errors.rb`**

- [ ] **Step 4: Run the Ruby suite**

Run: `ruby test/run_all.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb mcp_for_sketchup/mcp_for_sketchup/core/errors.rb test/test_server_hardening.rb test/test_errors.rb
git commit -m "fix: cap queued frames and accepts per tick, time out only stalled writes, survive JSON nesting errors"
```

---

### Task 4: Strict arguments, log escaping, and an eval gate that closes for good (M-29, M-31)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb`, `core/logger.rb`, `core/config.rb`
- Test:
  - `test/test_dispatch_strict_args.rb` (new);
  - `tests/test_contract.py`;
  - `test/test_logger.rb`;
  - `test/test_config.rb`;
  - any Ruby test that sends an argument the table does not allow (fix the test's arguments, not the table).

**Interfaces:**
- Produces:
  - `Dispatch::ALLOWED_ARGS`: a frozen Hash from wire name to `%w[...]`.
  - `Dispatch.check_arguments!(tool, params)`, called first in `call_handler`. A tool without an entry falls through to the existing `-32601`.
  - `Core::Logger.sanitize(text) -> String`.

The table (exactly; the order inside each `%w[]` is free):

| wire name | allowed arguments |
|---|---|
| `create_component` | `type position dimensions name segments` |
| `delete_component`, `get_component_info` | `id` |
| `transform_component` | `id position rotation scale` |
| `set_material` | `id material` |
| `boolean_operation` | `target_id tool_id operation delete_originals` |
| `chamfer_edges` | `entity_id distance edge_indices` |
| `fillet_edges` | `entity_id radius segments edge_indices` |
| `create_mortise_tenon` | `mortise_id tenon_id width height depth offset_x offset_y offset_z` |
| `export`, `export_scene` | `format width height` |
| `eval_ruby` | `code` |
| `list_components` | `recursive max_depth limit offset response_format` |
| `find_components` | `name layer type max_depth limit offset response_format` |
| `create_layer` | `name` |
| `get_viewport_screenshot` | `max_size view_preset zoom_extents style restore_view` |
| `get_model_info`, `list_layers`, `get_selection`, `undo`, `get_version` | none |

An unknown argument is `-32602 "unknown argument '<name>' for <tool>"`, naming the first unknown key in the order the client sent them.

The other two changes:
- **Log escaping.** `Logger.sanitize` replaces `\n` → `\\n`, `\r` → `\\r`, `\t` → `\\t`, and every other byte in `0x00–0x1F` or `0x7F` → `\\xNN` (two uppercase hex digits). `log` sanitizes `msg`, and `log_error` sanitizes each backtrace line it emits.
- **Eval gate.** In `Config.update!`, `eval_enabled: false` is written before every other key and is never rolled back: after a failed save the runtime value stays `false`. `eval_enabled: true` is still written last and rolled back.

- [ ] **Step 1: Write the failing tests**

- `test_dispatch_strict_args.rb`:
  - `test_every_routed_wire_name_has_an_entry`: `DispatchTable.routes` wire names equal `ALLOWED_ARGS.keys`.
  - `test_unknown_argument_is_refused`: `call_handler("delete_component", {"id" => "1", "colour" => "red"})` raises `-32602` with exactly `"unknown argument 'colour' for delete_component"`.
  - `test_allowed_arguments_reach_the_handler`, with a stubbed `Handlers::Geometry.delete_component`.
- `tests/test_contract.py`, `test_ruby_allows_every_argument_a_tool_sends`. It parses `ALLOWED_ARGS` from `dispatch.rb` as text, like `_ruby_read_only_tools`. For every tool in `mcp.list_tools()`:
  - the wire name is `WIRE_NAMES.get(name, name)`;
  - the sent names are the `inputSchema` properties, with `id` renamed to `entity_id` for `chamfer_edge` and `fillet_edge`;
  - sent ⊆ allowed;
  - allowed − sent is exactly `{"create_component": {"segments"}, "chamfer_edges": {"edge_indices"}, "fillet_edges": {"edge_indices"}, "export": {"width", "height"}}` (empty for the others);
  - `export_scene` allows the same as `export`.
- `test_logger.rb` `test_control_characters_are_escaped`: `log("WARN", "a\nb\rc\td\x01e\x7Ff")` emits one line containing `a\nb\rc\td\x01e\x7Ff`, with the backslashes literal.
- `test_config.rb` `test_closing_the_eval_gate_is_saved_first_and_stays_closed`: a store that fails on `host`. `update!(…, eval_enabled: false)` raises, the store saw `eval_enabled=false` written first, and `Config.eval_enabled` is false afterwards (the snapshot had `true`).

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_dispatch_strict_args.rb; uv run --locked pytest tests/test_contract.py -q`
Expected: failures on the missing `ALLOWED_ARGS`.

- [ ] **Step 3: Implement the table, `sanitize`, and the `update!` order**

- [ ] **Step 4: Run both suites**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb mcp_for_sketchup/mcp_for_sketchup/core/logger.rb mcp_for_sketchup/mcp_for_sketchup/core/config.rb test/test_dispatch_strict_args.rb tests/test_contract.py test/test_logger.rb test/test_config.rb
git commit -m "fix: refuse unknown tool arguments, escape control characters in logs, keep a closed eval gate closed"
```

---

### Task 5: The handshake on the client (M-06, M-31 Python part)

**Files:**
- Create: `src/sketchup_mcp/auth.py`
- Modify: `src/sketchup_mcp/config.py`, `errors.py`, `connection.py`, `compat.py`, `tools.py`
- Test:
  - new: `tests/test_auth.py`;
  - `tests/conftest.py`;
  - `tests/test_connection.py`, `tests/test_version_handshake.py`;
  - `tests/test_config.py`, `tests/test_tools.py`, `tests/test_version_tool.py`, `tests/test_compat.py`;
  - `tests/test_framing.py` (if its fake server answers `hello`).

**Interfaces:**
- Consumes: the wire contract from Task 2.
- Produces:
  - `config.TOKEN: str | None`: `SKETCHUP_MCP_TOKEN` stripped of surrounding whitespace; `None` when unset or empty.
  - `auth.TOKEN_RE`.
  - `auth.new_nonce() -> str`: `secrets.token_hex(32)`, looked up at call time so tests can monkeypatch it.
  - `auth.proof(token, role, client_nonce, server_nonce) -> str`.
  - `auth.check_token(token) -> str`: returns the token or raises `AuthenticationError`.
  - `auth.COPY_TOKEN_HINT`.
  - `errors.AuthenticationError(SketchUpError)`: code `-32003`, `__init__(self, message)`.
  - `SketchUpConnection(host, port, timeout, token=None)`. `get_connection` passes `config.TOKEN`.
  - `compat._msg_ruby_unauthenticated(server_version)`.

Messages, exactly. `COPY_TOKEN_HINT` is:
`"Copy the token from SketchUp (Extensions → MCP Server → Settings...) into SKETCHUP_MCP_TOKEN in the MCP client's config, then restart the MCP client."`

| Case | Message |
|---|---|
| unset | `f"SKETCHUP_MCP_TOKEN is not set. {COPY_TOKEN_HINT}"` |
| malformed | `f"SKETCHUP_MCP_TOKEN is not a token from the SketchUp plugin: expected 64 hex characters, got {len(token)}. {COPY_TOKEN_HINT}"` |
| server proof wrong | `f"The server at {host}:{port} does not know this token: SKETCHUP_MCP_TOKEN is wrong, or the server is not the SketchUp MCP plugin. {COPY_TOKEN_HINT}"` |
| server answers `-32003` | `f"SketchUp at {host}:{port} rejected the token (authentication failed). {COPY_TOKEN_HINT}"` |
| plugin predates auth (`IncompatibleVersionError`) | `f"SketchUp plugin v{rv} pre-dates socket authentication, which sketchup-mcp2 v{CLIENT_VERSION} requires. Install the latest mcp_for_sketchup .rbz from the GitHub releases page. Call `get_version` to inspect handshake state."` |
| non-finite argument (`-32602`) | `f"arguments for '{name}' contain a number that is not finite (NaN or infinity)"` |

Client flow in `connect()`:
1. `auth.check_token(self.token)` before `open_connection`, so no socket is opened without a well-formed token.
2. `_handshake` sends `hello` with `client_nonce = auth.new_nonce()`.
3. It checks `server_version` with `compat.check_ruby_version` first.
4. A missing `server_nonce` or `server_proof` → `IncompatibleVersionError(_msg_ruby_unauthenticated)`.
5. It compares the proof with `hmac.compare_digest`; a mismatch → `AuthenticationError`, without sending `auth`.
6. It sends `auth {client_proof}`. An answer of `-32003` → `AuthenticationError` with the rejected message; otherwise store `client_id`.

`connect()`'s existing `except BaseException` already closes the socket on any failure.

Elsewhere:
- `_send_once` serializes with `json.dumps(request, allow_nan=False)`. Its `ValueError` becomes the non-finite `-32602` before anything is written.
- `SketchUpError.__init__` keeps a dict `data`, turns `None` into `{}`, and wraps anything else as `{"raw": data}`.
- In `tools.py`, `_tool_error` returns `_error(e.message)` for an `AuthenticationError`: verbatim, ruling 4. `get_version` keeps folding every `SketchUpError` into its payload's `error`.

- [ ] **Step 1: Write the failing tests**

Fixtures and helpers:
- `conftest.py` gets `TEST_TOKEN` and the vector constants, a `fixed_nonce` fixture that monkeypatches `sketchup_mcp.auth.new_nonce` to return `"a" * 64`, and `make_connection` passing `token=TEST_TOKEN`.
- `test_connection.py`'s `FakeServer` scripts become `hello_ok(version)` (server nonce `"b"*64`, proof `SERVER_PROOF`) followed by `auth_ok(client_id)`.

Tests:
- `test_auth.py`:
  - `test_proofs_match_the_cross_language_vector`;
  - `test_new_nonce_is_64_hex`;
  - `test_check_token_names_a_missing_token`;
  - `test_check_token_names_the_length_of_a_malformed_one` (`"abc"` → `"got 3"`).
- `test_config.py` `test_token_is_stripped_of_whitespace`: env `"  " + TEST_TOKEN + "\n"` gives `config.TOKEN == TEST_TOKEN`. An empty value gives `None`.
- `test_connection.py`:
  - `test_handshake_sends_the_nonce_and_the_client_proof`: the first written frame's params are `{"client_version": CLIENT_VERSION, "client_nonce": "a"*64}`; the second is `{"method": "auth", "params": {"client_proof": CLIENT_PROOF}, "id": 0}`; `_client_id` is set.
  - `test_wrong_server_proof_is_refused_without_auth`: `AuthenticationError` with `"does not know this token"`, exactly one frame written, and the socket closed.
  - `test_plugin_without_nonce_is_too_old`: the 0.4.0-shaped reply `{server_version, client_id}` gives `IncompatibleVersionError` with `"pre-dates socket authentication"`.
  - `test_rejected_proof_is_an_authentication_error`: `-32003` on `auth` gives `AuthenticationError` with `"rejected the token"` and the hint.
  - `test_malformed_token_answers_without_connecting`: `token="abc"`; `asyncio.open_connection` monkeypatched to fail the test if called; `ensure_connected()` raises `AuthenticationError`.
  - `test_missing_token_answers_without_connecting`: the same with `token=None`.
  - `test_non_finite_argument_is_refused_before_sending`: `send_command("create_component", {"position": [float("nan"), 0, 0]})` raises `-32602` with `"not finite"`, and nothing is written.
- `test_tools.py`:
  - `test_authentication_error_is_an_error_result_verbatim`: `isError`, with text equal to the message (no `[` prefix).
  - `test_non_dict_error_data_is_normalised`: `SketchUpError(1, "m", "x").data == {"raw": "x"}`.
- `test_version_tool.py` `test_missing_token_is_in_the_payload`: `compatible` false; `error` starts with `"SKETCHUP_MCP_TOKEN is not set."`.

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run --locked pytest tests/test_auth.py tests/test_connection.py -q`
Expected: `ModuleNotFoundError: sketchup_mcp.auth`, then handshake assertion failures.

- [ ] **Step 3: Implement `auth.py` and the changes above**

- [ ] **Step 4: Run the Python suite**

Run: `uv run --locked pytest tests/ -q`
Expected: all green, plus the opt-in contract test skipped.

- [ ] **Step 5: Commit**

```bash
git add src/sketchup_mcp/auth.py src/sketchup_mcp/config.py src/sketchup_mcp/errors.py src/sketchup_mcp/connection.py src/sketchup_mcp/compat.py src/sketchup_mcp/tools.py tests/
git commit -m "feat!: prove the token to SketchUp and check SketchUp's proof before any tool call"
```

(`tests/` covers only the files this task changed; check `git status` before committing.)

---

### Task 6: Startup bound, start line, `--version`, and the harnesses (M-21 Python part, startup timeout)

**Files:**
- Modify:
  - `src/sketchup_mcp/app.py`, `src/sketchup_mcp/server.py`;
  - `tests/test_contract_wire.py`;
  - `examples/smoke_check.py`, `examples/smoke_multi_client.py`.
- Test: `tests/test_app.py`, `tests/test_server_cli.py` (new)
- Local, not committed: `.superpowers/sdd/hot_reload.py`. It needs `token=` from `SKETCHUP_MCP_TOKEN` and the new handshake, so it only works with the Task 9 build.

**Interfaces:**
- Consumes: Task 5's `SketchUpConnection(…, token=)` and `config.TOKEN`; Task 2's echo server reading `SKETCHUP_MCP_TOKEN`.
- Produces: `app.STARTUP_CONNECT_TIMEOUT = 5.0`.

Changes:
- **Startup.**
  - `server_lifespan` logs one INFO line after `setup_logging()`: `"sketchup-mcp2 %s starting; SketchUp plugin expected at %s:%s"` (version, `config.HOST`, `config.PORT`).
  - It wraps the eager connect in `asyncio.wait_for(conn.ensure_connected(), STARTUP_CONNECT_TIMEOUT)`.
  - On `asyncio.TimeoutError` it logs a warning, `"SketchUp did not answer within 5s at startup; the first tool call will connect"`, and starts degraded.
- **`--version`.** `server.main()` parses arguments with `argparse` (`prog="sketchup-mcp2"`): `--version` prints `sketchup-mcp2 <__version__>` and exits 0. With no arguments it runs `mcp.run()` as before.
- **Contract test.** `test_contract_wire.py` starts the echo server with `env={**os.environ, "SKETCHUP_MCP_TOKEN": TEST_TOKEN}` and builds its `SketchUpConnection` with `token=TEST_TOKEN`.
- **Examples.** `smoke_check.py` and `smoke_multi_client.py` pass `token=config.TOKEN`. Without a token they print the unset-token message from Task 5 and exit with status 2 before connecting. Their header comments say `SKETCHUP_MCP_TOKEN` must be set.

- [ ] **Step 1: Write the failing tests**

- `test_app.py` `test_startup_connect_is_bounded`: `STARTUP_CONNECT_TIMEOUT` is monkeypatched to `0.05`, and `ensure_connected` sleeps 10 s. The lifespan enters within 1 s, and the warning is logged.
- `test_app.py` `test_startup_logs_version_host_and_port`: `caplog` holds one line with `__version__`, `config.HOST` and `str(config.PORT)`.
- `test_server_cli.py` `test_version_flag_prints_the_version`: `main()` with `sys.argv = ["sketchup-mcp2", "--version"]` raises `SystemExit(0)`, and stdout is `f"sketchup-mcp2 {__version__}\n"`.

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run --locked pytest tests/test_app.py tests/test_server_cli.py -q`
Expected: the lifespan hangs past 1 s (assertion), and `--version` runs the server (fails).

- [ ] **Step 3: Implement the startup bound, the start line, `--version`, the contract-test token and the examples' token**

- [ ] **Step 4: Run all three gates**

Run: `uv run --locked pytest tests/ -q && SKETCHUP_MCP_CONTRACT=1 uv run --locked pytest tests/test_contract_wire.py -q && ruby test/run_all.rb`
Expected: all green; the contract test passes 1.

- [ ] **Step 5: Commit**

```bash
git add src/sketchup_mcp/app.py src/sketchup_mcp/server.py tests/test_app.py tests/test_server_cli.py tests/test_contract_wire.py examples/smoke_check.py examples/smoke_multi_client.py
git commit -m "feat: bound the startup connect, log the start, add --version, carry the token through the harnesses"
```

---

### Task 7: Settings — the token, Regenerate, and one loopback check (M-06 UI, §7.3)

**Files:**
- Create: `mcp_for_sketchup/mcp_for_sketchup/core/net.rb` (LOAD_ORDER in `main.rb`: after `core/auth`)
- Modify:
  - `core/server.rb`, `core/application.rb`;
  - `ui/settings_dialog.rb`, `ui/settings.html`;
  - `main.rb`.
- Test:
  - new: `test/test_net.rb`;
  - `test/test_server_bind_warning.rb`, `test/test_settings_dialog.rb`;
  - `test/test_application.rb`, `test/test_server_multi_client.rb`.

**Interfaces:**
- Consumes: Task 1's `Config.token` and `Config.regenerate_token!`.
- Produces:
  - `Core::Net.loopback?(host) -> bool`;
  - `Server#close_all_clients(reason)`;
  - `Application.disconnect_clients(reason)`: a no-op when stopped;
  - dialog callbacks `regenerate_token` and `check_host(host)`;
  - `load_state_payload` keys `token` and `host_loopback`;
  - the JS hooks `window.onHostCheck({host, loopback})` and `window.onTokenResult({ok, error?})`.

Behaviour:
- **`Net.loopback?(host)`.** `Addrinfo.getaddrinfo(host, nil, nil, :STREAM)`; true when the list is non-empty and every address is `ipv4_loopback?` or `ipv6_loopback?`; false for an empty host or a `SocketError`. `Server#warn_if_exposed_bind` uses it in place of `LOOPBACK_HOSTS`, which is deleted.
- **Bind warning (server log, WARN):** `"bound to non-loopback host #{host}: other machines can reach the MCP server. A client needs the token to connect, but the traffic is not encrypted; on a network you do not trust, bind 127.0.0.1 and use an SSH tunnel (README → Security model)."`
- **Dialog, token row.** A read-only text field with the token, plus Copy and Regenerate.
  - Copy selects the field and calls `document.execCommand('copy')`. On success it shows `Copied`; otherwise `Press Ctrl+C to copy` (the text stays selected).
  - Regenerate calls `sketchup.regenerate_token()`. Ruby defers through `UI.start_timer(0, false)` and asks `MB_YESNO`: `"Regenerate the MCP token?\n\nEvery connected MCP client is disconnected now, and each one needs the new token in SKETCHUP_MCP_TOKEN (and a restart of that client) before it can connect again."`
  - On Yes: `Config.regenerate_token!`, then `Application.disconnect_clients("token_regenerated")`, then `applyState(load_state_payload)`.
  - If saving fails: `onTokenResult({ok: false, error: "Could not save the new token: <message>"})`, and the old token stays.
- **Dialog, host warning.** It comes from `check_host`, debounced 300 ms on input, and from `host_loopback` on load. For a non-loopback host: `"⚠ #{host} lets other machines reach the server. They need the token to connect, but the traffic is not encrypted: on a network you do not trust, use 127.0.0.1 and an SSH tunnel."` With Ruby evaluation checked, append `" Ruby evaluation is on: a client with the token can run arbitrary Ruby."` The old wildcard-only JavaScript check is removed.
- **Eval texts.** The eval warning paragraph: `"Lets any MCP client that has the token run arbitrary Ruby with full file and shell access. ON by default; uncheck it unless you trust every client you give the token to."` `confirm_eval_enable` replaces its second paragraph with: `"This lets any MCP client that has the token run arbitrary Ruby code inside SketchUp with FULL access to your filesystem, network, and shell. The token keeps out clients that do not have it; the traffic itself is not encrypted."`

- [ ] **Step 1: Write the failing tests**

- `test_net.rb`:
  - `test_loopback_hosts`: true for `127.0.0.1`, `127.0.0.2`, `::1`, `localhost`.
  - `test_exposed_hosts`: false for `0.0.0.0`, `::`, `192.168.1.5`, `""`.
  - `test_unresolvable_host_is_not_loopback`: `Addrinfo.getaddrinfo` stubbed to raise `SocketError`.
- `test_server_bind_warning.rb`:
  - `test_lan_address_is_warned_about`: `192.168.1.5` logs a WARN containing `"token"` and `"not encrypted"`.
  - `test_localhost_is_not_warned_about`.
- `test_server_multi_client.rb` `test_close_all_clients_drops_their_queued_frames`: two handshaked clients, one with a `tools/call` queued. After `close_all_clients("token_regenerated")` both sockets are closed and `@clients` is empty. The next `process_frame_queue` writes nothing and raises nothing.
- `test_application.rb`:
  - `test_disconnect_clients_reaches_the_server`;
  - `test_disconnect_clients_when_stopped_does_nothing`.
- `test_settings_dialog.rb`:
  - `test_payload_carries_the_token_and_the_loopback_flag`;
  - `test_regenerate_yes_saves_disconnects_and_refreshes`, with stubbed `messagebox` → `IDYES`, `regenerate_token!` and `disconnect_clients`;
  - `test_regenerate_no_changes_nothing`;
  - `test_regenerate_save_failure_reports_and_keeps_the_token`;
  - `test_check_host_answers_on_host_check`: `execute_script` receives `window.onHostCheck(...)` with `"loopback":false` for `192.168.1.5`;
  - `test_eval_confirm_mentions_the_token`.

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_net.rb; ruby test/test_settings_dialog.rb`
Expected: `Core::Net` undefined, and missing callbacks.

- [ ] **Step 3: Implement `net.rb`, `close_all_clients`, `disconnect_clients`, the dialog callbacks and the HTML**

- [ ] **Step 4: Run the Ruby suite**

Run: `ruby test/run_all.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/net.rb mcp_for_sketchup/mcp_for_sketchup/core/server.rb mcp_for_sketchup/mcp_for_sketchup/core/application.rb mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb mcp_for_sketchup/mcp_for_sketchup/ui/settings.html mcp_for_sketchup/mcp_for_sketchup/main.rb test/test_net.rb test/test_server_bind_warning.rb test/test_server_multi_client.rb test/test_application.rb test/test_settings_dialog.rb
git commit -m "feat: show, copy and regenerate the token in Settings; warn about any non-loopback host"
```

---

### Task 8: Docs, wording and the repository (M-23, M-27, §7.5)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/sketchup-ruby-cookbook.md`, `docs/release.md` (wording only)
- Modify (message text):
  - `mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb` (the gate message);
  - `core/application.rb` (the start-failure messagebox);
  - `src/sketchup_mcp/prompts.py` (§8, plus one line in §5);
  - `examples/smoke_check.py`, `examples/smoke_multi_client.py` (header comments).
- Create: `SECURITY.md`
- Test: `test/test_eval_gate.rb`, `tests/test_tools.py`, `tests/test_prompts.py` (the pinned gate message)

Content:
- **The menu.** Every `Plugins → MCP Server → …` in the files above becomes `Extensions → MCP Server → …`. The eval-gate message becomes `"eval_ruby is disabled. Open Extensions → MCP Server → Settings... and check 'Enable Ruby evaluation'. …"`, the rest unchanged. Its pins move with it.
- **README.**
  - **Quickstart** gains step "Copy the token": Settings → Copy, then `SKETCHUP_MCP_TOKEN` in the `.mcp.json` env block, with an example.
  - **Python side** lists `SKETCHUP_MCP_TOKEN`.
  - **Ruby side** lists the Token row (read-only, Copy, Regenerate disconnects every client).
  - **Security model** is rewritten for spec §7.1–7.3:
    - the token is required on every address, loopback included;
    - what it protects (who can connect) and what it does not (the traffic is not encrypted, and someone on the path can read and change it after the handshake);
    - setup for one machine, the SSH tunnel and a LAN address;
    - Regenerate.
  - **Troubleshooting** gains `SKETCHUP_MCP_TOKEN is not set` / `does not know this token` / `rejected the token`.
  - **Capabilities** describes the two-step handshake and drops "supported range" (M-23).
- **CLAUDE.md.**
  - The version-handshake bullet becomes the handshake bullet: the exchange, the proofs, `-32001` before `-32003`, the 30 s deadline over the whole exchange, the 4 KiB pre-handshake frame cap, and both rulings 1 and 2.
  - The eval-gate bullet: a direct TCP client needs the token, and with it bypasses the per-call review.
  - The configuration tables gain the token and `SKETCHUP_MCP_TOKEN`.
  - "No ENV variables are read on the Ruby side" becomes "The plugin reads no settings from the environment; `handlers/export.rb` takes its temp directory from `TEMP`/`TMP`" (M-23).
  - The test counts are updated.
  - `core/auth.rb` and `core/net.rb` join the core row.
- **prompts.py §5** gains: `"- If a tool says SKETCHUP_MCP_TOKEN is not set or the token is wrong, repeat the message to the user verbatim: only they can copy the token from SketchUp."`
- **`SECURITY.md`** (M-27). Report vulnerabilities privately through GitHub's private vulnerability reporting (Security tab → Report a vulnerability), not in public issues. In scope: the plugin's TCP server and handshake, the eval gate, and the Python client. Fixes go into the latest release.
- **The repository setting.** Enabling private vulnerability reporting is a setting: ask the user to switch it on (Settings → Code security), or to approve `gh api -X PUT repos/zinin/sketchup-mcp2/private-vulnerability-reporting`. Do not run it unasked.

- [ ] **Step 1: Update the pinned gate-message tests to the `Extensions` wording, and add `test_prompts.py` `test_prompt_says_to_relay_token_messages`**

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_eval_gate.rb; uv run --locked pytest tests/test_tools.py tests/test_prompts.py -q`
Expected: the gate message still says `Plugins`; the prompt line is missing.

- [ ] **Step 3: Edit the texts and docs; create `SECURITY.md`**

- [ ] **Step 4: Run both suites; check that no `Plugins →` is left outside `full-review/` and `docs/superpowers/`**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q && ! grep -rn "Plugins →" --include=*.rb --include=*.py --include=*.md --include=*.html . | grep -v "^./full-review\|^./docs/superpowers\|^./.venv"`
Expected: green, and the grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md SECURITY.md docs/sketchup-ruby-cookbook.md docs/release.md mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb mcp_for_sketchup/mcp_for_sketchup/core/application.rb src/sketchup_mcp/prompts.py examples/smoke_check.py examples/smoke_multi_client.py test/test_eval_gate.rb tests/test_tools.py tests/test_prompts.py
git commit -m "docs: explain the token and its limits, name the Extensions menu, add SECURITY.md"
```

---

### Task 9: Live checks with an installed build (spec §7.6)

The controller runs this task with the user; it needs SketchUp 2027 and an installed build. No code changes are expected. A failure goes back to the task that owns the code, with a failing test first.

- [ ] **Step 1: Build the plugin.**

Run: `cd mcp_for_sketchup && ruby package.rb && cd ..` (through the build runner).
Expected: one `.rbz` in `mcp_for_sketchup/`.

- [ ] **Step 2: The user installs it.**
  1. Extension Manager: uninstall the 0.4.0 plugin.
  2. Restart SketchUp, install the `.rbz`, restart again.
  3. Start the server, then copy the token from `Extensions → MCP Server → Settings...`.
  4. Put it into `SKETCHUP_MCP_TOKEN` in `/opt/github/zinin/.mcp.json`.
  5. Reconnect `/mcp`.

  The user does every step: an extension install and the session config are theirs.
- [ ] **Step 3: Check, recording each result:**
  1. **With the token.** `get_version` is compatible, and `get_model_info` works.
  2. **Wrong token** (one character changed, client restarted). The tool answers verbatim with `does not know this token` and the hint; the server log has no `auth_failed` (the client stopped at step 3 of the exchange).
  3. **A client that skips verification and sends a wrong `client_proof`** (a scratch script on a raw socket). It gets `-32003`, and the server log has WARN `auth_failed` with no token or proof in it.
  4. **No token.** The tools answer `SKETCHUP_MCP_TOKEN is not set…`, and the server log shows no connection.
  5. **A fake server on another port** that answers `hello` with a made-up proof (a scratch script). The client refuses it with `does not know this token` and never sends `auth`.
  6. **A 0.4.0 client** (a raw `hello` without `client_nonce`, version `0.4.0`). It gets `-32001` with `pre-dates socket authentication` and the upgrade hint.
  7. **Regenerate.**
     - The confirm appears, and the connected session is disconnected.
     - The next tool call fails with `does not know this token`.
     - With the new token in `.mcp.json` and `/mcp` reconnected, it works again.
     - Copy puts the token on the clipboard.
  8. **Settings with a LAN address** typed in. The warning appears after the debounce, without saving; with eval checked, the extra sentence appears.
  9. **Smoke.** `SKETCHUP_MCP_TOKEN=<token> SKETCHUP_MCP_HOST=192.168.20.20 uv run --locked python examples/smoke_check.py` passes all steps.
  10. **Clean start and transport.** The plugin loads with no error in the Ruby console (clean start: the hot-reload blind spot from block A), and `get_viewport_screenshot` returns an image (a frame larger than 4 KiB after the handshake).
- [ ] **Step 4: Report the results in the ledger; leave the model as it was found (empty template; probes named `probe_*` and erased).**

---

### Task 10: A compact Settings window (after the live check of Task 7)

The first live look showed the window too tall: on the user's screen at their scaling, Save and Cancel fell below its edge (a blank error line reserved under every field, three multi-line warnings, a separate status block, height 780). The user chose the compact single column from three mockups (compact column, tabs, two columns). The checkpoint plan: this task, then a new build, then Task 9.

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/ui/settings.html`, `ui/settings_dialog.rb`
- Test: `test/test_settings_dialog.rb`

**Layout** (the chosen mockup):
- **Window and frame.**
  - The window is `DIALOG_WIDTH = 580` × `DIALOG_HEIGHT = 440`. `build_dialog` also calls `dialog.set_size` with them, because SketchUp may otherwise restore the size it remembered under `preferences_key`.
  - The body is a column: `<main>` (scrolls when it has to) above a `<footer>` holding Cancel and Save, which always stays in view.
- **Rows inside `<main>`, top to bottom:**
  1. The status line: `● Running on host:port`, plus ` — saved settings differ; restart to apply` when they do, or `○ Stopped`.
  2. One row: Host, then Port.
  3. One row: Token (read-only, monospace, ellipsis), Copy, Regenerate, (?).
  4. One row: Log level, then ☐ Also to file. The file path row appears only while that box is checked.
  5. ☑ Ruby evaluation — any client with the token can run arbitrary Ruby, then (?).
- **Showing text only on demand.**
  - An error or note line takes no space until it has text (`:empty { display: none }`).
  - A non-loopback host shows one warning line, `⚠ Other machines can connect (they need the token); the traffic is not encrypted`, and its (?) opens the full text.
  - Each (?) is a button with `data-toggle="<id>"` that shows or hides the element with that id. The targets are `host-warning-text`, `token-help` and `eval-warning`; `#eval-warning` keeps its text.

- [ ] **Step 1: Write the failing tests** (`test_settings_dialog.rb`)
  - `test_errors_and_notes_take_no_space_until_shown`
  - `test_buttons_sit_in_a_footer_outside_the_scrolling_content`
  - `test_host_and_port_share_a_row`
  - `test_log_path_shows_only_when_logging_to_file`
  - `test_long_texts_open_on_demand`
  - `test_build_dialog_sets_the_compact_size`, with a fake `UI::HtmlDialog` that records its options and `set_size`
- [ ] **Step 2: Run them to verify they fail**
- [ ] **Step 3: Re-lay out `settings.html` and size the dialog**
- [ ] **Step 4: Run the Ruby suite; build the `.rbz` for Task 9**
- [ ] **Step 5: Commit** (`feat: a compact Settings window`)

---

### Task 11: The token in a file of its own (after the live check of Task 9)

The live check found that a regenerated token does not survive a crash: SketchUp writes `Sketchup.write_default` preferences to disk only when it closes normally, so after Regenerate and a forced kill the old token came back and the new one was refused. The user chose a file of the plugin's own; no migration from the preference (it never shipped). Spec §7.1 updated.

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/config.rb`
- Test: `test/test_config_token.rb` (rewritten for the file)
- Docs: `CLAUDE.md`, `README.md`

**Interfaces:**
- `Config.token_path(env: ENV, platform: RUBY_PLATFORM, home: Dir.home) -> String`: `<base>/MCPforSketchUp/auth_token`, base `%APPDATA%` (Windows), `~/Library/Application Support` (macOS), `~/.config` (anything else).
- `Config.load_token!(path = token_path)` and `Config.regenerate_token!(path = token_path)` keep their contracts (a valid token is kept; a missing or malformed one is replaced and written, a failed write still serves the session; Regenerate writes before the token takes effect and raises on a failed write). A read error other than a missing file gives this session a new token and leaves the file alone. `TOKEN_KEY` goes.
- The write: directory `0700`, temporary file `0600` next to the target, flushed and fsynced, then renamed over it; a failed write leaves no temporary file.

- [ ] **Step 1: Rewrite `test/test_config_token.rb` for the file** (temporary directory per test): creates and writes; keeps a valid token (a trailing newline is fine, the file stays as it was); replaces a malformed one and warns with the path, not the contents; keeps the token when the write fails; leaves a file it cannot read alone; regenerate writes before it takes effect, leaves no temporary file; a failed rename keeps the old token in memory and on disk; file `0600` and directory `0700` (POSIX); `token_path` per platform.
- [ ] **Step 2: Run it to verify it fails**
- [ ] **Step 3: Implement in `config.rb`**
- [ ] **Step 4: Run the Ruby suite; update CLAUDE.md and README; build the `.rbz`**
- [ ] **Step 5: Commit** (`fix: keep the token in a file written at once, so Regenerate survives a crash`)
- [ ] **Step 6: Live: Regenerate, kill SketchUp, restart — the new token is accepted, the old one refused.**

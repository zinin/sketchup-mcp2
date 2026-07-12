# Parsed Design Review Issues — Version-Compat Check — Iteration 1

**Date:** 2026-05-16
**Design:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
**Plan:** `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
**Merged review source:** `docs/superpowers/specs/2026-05-16-version-compat-check-review-merged-iter-1.md`
**Reviewers:** codex (gpt-5.5/xhigh), ccs-glm (glm-5.1), kimi (K2.6), minimax (M2.7), deepseek (V4 Pro)

All issues below are **NEW** (this is iteration 1 — no previous answers to match against).

---

## PARSED_ISSUES

---

### [CRITICAL-1] `request_id = nil` when version-mismatch fires in `dispatch.rb`
**SOURCES:** codex, ccs-glm (W4 partial), kimi (CI-3), deepseek (#1) — **4/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** Plan Task 4.3 inserts `Core::Compat.check_python_version(request["client_version"])` *before* `request_id = request["id"]` (plan:695-715). If the check raises `StructuredError(-32001)`, the existing `rescue` block in `dispatch.rb:44` uses `request_id`, which is still `nil`. The error response goes out with `"id": null` instead of the real request id — a JSON-RPC 2.0 violation. Additionally, `is_notification = !request.key?("id")` is also computed *after* the check, so a notification with mismatch will receive an unsolicited error response (spec: "The Server MUST NOT reply to a Notification").

**OPTIONS:**
1. **Reorder: assign `request_id`/`is_notification` BEFORE the compat check** (рекомендуется) — move both lines above the compat check; if `is_notification`, log the mismatch and return without writing a response; otherwise let the existing rescue produce a properly-id'd `-32001` envelope.
2. **Wrap the check in its own try/rescue** that explicitly captures `request["id"]` and `request.key?("id")` at raise-time — more surgical but duplicates logic already present in the outer rescue.
3. **Defer the check to after envelope validation but pass an explicit `request_id` argument to a helper** that handles notification suppression — cleaner separation but more refactoring.

---

### [CRITICAL-2] `server_version` not injected into `encode_response_body` fallback envelope
**SOURCES:** codex, ccs-glm (W1), kimi (CI-2), minimax (#1) — **4/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** Plan Task 4.4 sets `response["server_version"] = Core::Compat::RUBY_VERSION` as the first line of `write_response`, then calls `encode_response_body(response)` (plan:724-734). But `encode_response_body` has a rescue at `server.rb:165-177` that, on `JSON::GeneratorError`, *replaces* the response with a new hash built from `Errors.build_error_response(...)` — and that new hash never gets `server_version`. Python then receives an envelope without `server_version`, triggers `IncompatibleVersionError("pre-dates")`, and masks the real encoding error. The plan's claim that the choke-point injection covers both success and error paths is therefore false.

**OPTIONS:**
1. **Move `server_version` injection into `encode_response_body` after the fallback hash is built** (рекомендуется) — guarantees every emitted envelope, regardless of which path produced it, carries the field; single source of truth.
2. **Add `server_version` to `Errors.build_error_response(...)` itself** — keeps fallback symmetric with normal errors but couples a transport concern (handshake) into the error builder.
3. **Inject `server_version` a second time in `write_response` after `encode_response_body` returns** — requires decoding/re-encoding the JSON body, expensive and brittle; not recommended.

---

### [CRITICAL-3] `get_version` tool wrapper only catches `ConnectionError`, not `SketchUpError`
**SOURCES:** codex, ccs-glm (implicit via Q3), kimi (CI-1), deepseek (#2) — **4/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** Acceptance criterion in design §15 says `get_version` "returns a payload ... on every call regardless of mismatch state." Plan Task 7.3 catches only `ConnectionError` (plan:1263-1273). When a new 0.1.0 Python talks to a 0.0.3 Ruby (no `get_version` handler), Ruby returns `-32601 "unknown tool: get_version"`. `_send_once` raises `SketchUpError`, which escapes the tool wrapper. Same applies if any other JSON-RPC error envelope comes back. The diagnostic tool that's supposed to "always succeed" instead propagates an exception exactly when users need diagnostic info most.

**OPTIONS:**
1. **Add `except SketchUpError as e` next to the existing `except ConnectionError`** (рекомендуется) — returns the canonical "compatible=false, ruby_version=null, error=<msg>" payload; catches both the old-Ruby case (-32601) and any other Ruby-side error.
2. **Catch the broader `Exception`** — safer for unknown future error classes but masks real bugs; would need careful logging.
3. **Implement client-side fallback: if Ruby returns -32601 for `get_version`, treat as ruby_version="0.0.3-or-older"** — gives more informative output for the old-plugin case but introduces magic strings.

---

### [CRITICAL-4] `get_version` route absent from `_RETRY_SAFE_TOOLS` whitelist
**SOURCES:** codex, ccs-glm (C2), kimi (C-2), deepseek (#4) — **4/5 reviewers**
**SEVERITY:** Critical (consensus) — practically Concern
**STATUS:** NEW

**BODY:** `connection.py:43-54` defines `_RETRY_SAFE_TOOLS` — a whitelist of read-only tools eligible for automatic retry after a stale-socket detection. `get_version` is the most read-only tool in the entire codebase and the first thing users call when something is wrong. Without it in the whitelist, a stale socket on first-call-after-idle will surface as `_StaleSocketError` instead of being transparently retried. The plan adds the tool but never modifies the whitelist (`plan` files-to-modify list omits this change).

**OPTIONS:**
1. **Add `"get_version"` to `_RETRY_SAFE_TOOLS` in connection.py and add the change to plan Task 7** (рекомендуется) — one-line patch; matches the "diagnostic that always succeeds" promise.
2. **Document the omission with rationale** — defensible if there's a reason (e.g. "fail fast so user reconnects"), but currently no such reason is given.
3. **Make all read-only introspection tools automatically retry-safe by tagging them at registration time** — cleaner but out of scope for this feature.

---

### [CRITICAL-5] Wire-level bypass logic in design §8.2 contradicts plan and real protocol
**SOURCES:** codex, ccs-glm (C4), minimax (#3), deepseek (#5) — **4/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** Design §8.2 shows `if method != "get_version"` (design:402-410) — but in the real wire protocol Python always sends `method: "tools/call"` with the tool name in `params.name`. So the design's example bypass would *never* skip — every call (including `get_version`) would hit the version check. The plan (Task 4.3) silently rewrites this to `method == "tools/call" && params.name == "get_version"` (plan:706-710) but does not flag the design as incorrect. A future reader of design alone will implement the wrong check.

**OPTIONS:**
1. **Update design §8.2 pseudocode to match the plan's `tools/call`/`params.name` form, and add the request-format example from §6 alongside** (рекомендуется) — single source of truth.
2. **Add an explicit "see plan Task 4.3 for the corrected check" pointer in design §8.2** — less invasive but leaves the wrong code sample in place.
3. **Leave design as illustrative pseudocode with a disclaimer** — weakest fix; future readers will still hit the trap.

---

### [CRITICAL-6] Task 4 has hidden dependency on Task 5 — `test_server_compat.rb` cannot pass in Task 4
**SOURCES:** codex, deepseek (#3) — **2/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** Plan Task 4.1 creates `test/test_server_compat.rb` containing `require_relative ".../handlers/system"` and a test `test_dispatch_get_version_bypasses_client_version_check` that routes through `handlers/system` (plan:554-555, 607-618). But `handlers/system.rb` is created only in Task 5 (plan:821), and the `when "get_version"` route in `call_handler` is added in Task 5.4 (plan:844-853). Step 4.5 ("all tests green") is therefore impossible. Additionally, the test double `make_server_double` overrides `write_response` with a hand-written copy of the production logic (plan:670-675) — the test passes even if Task 4.4 never modifies the real `write_response`.

**OPTIONS:**
1. **Reorder Tasks: merge Task 5's `handlers/system.rb` + dispatch route into Task 4 (or do them before Task 4 tests)**; rewrite `make_server_double` to call the *real* `write_response` with a stub socket instead of overriding the method (рекомендуется) — TDD invariant restored; tests verify production code.
2. **Split Task 4 tests: move `test_dispatch_get_version_bypasses_*` and the `write_response` injection tests into a new Task 4b that runs after Task 5** — preserves task boundaries but adds a 4th task on the Ruby side.
3. **Use a no-op handler stub in Task 4 (`Dispatch.handlers[:get_version] = ->(p) { {} }`) and convert it to the real handler in Task 5** — keeps Task 4 self-contained; small extra code.

---

### [CRITICAL-7] Existing `tests/test_connection.py` (~20 tests) will break after Task 6
**SOURCES:** codex, ccs-glm (C1) — **2/5 reviewers**
**SEVERITY:** Critical
**STATUS:** NEW

**BODY:** `tests/test_connection.py` uses `encode_response()` (via conftest fixtures) to build mock responses; none of those include `server_version` (e.g. happy path at `test_connection.py:36`). After Task 6's inbound check, every response without `server_version` triggers `IncompatibleVersionError("pre-dates")`. The plan's expected count "98 passed" assumes 92 existing + 6 new, but the 20+ existing tests in `test_connection.py` will fail. Files-to-MODIFY list (plan:38-50) does not include `tests/test_connection.py` or `tests/conftest.py`. The same problem exists on Ruby side: `test/test_view.rb:264` calls `Dispatch.handle` without `client_version`.

**OPTIONS:**
1. **Update `conftest.py::encode_response()` (or `fake_streams` helper) to inject `server_version=compat.MAX_RUBY` by default**, and update Ruby test fixtures with a `client_version=Compat::MIN_PYTHON` default (рекомендуется) — one-place fix; existing tests stay focused on transport concerns; add a separate negative-case test for missing fields.
2. **Add `server_version`/`client_version` explicitly to every existing test** — explicit but mechanical; ~20+ edits.
3. **Make the inbound check opt-out via a `_skip_compat_for_tests` flag set in conftest** — fragile; couples production to tests.

---

### [CONCERN-1] Test double `make_server_double` duplicates production logic
**SOURCES:** codex, ccs-glm (W2), kimi (C-5), minimax (#2) — **4/5 reviewers**
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** Plan Task 4.1's `make_server_double` overrides `write_response` with a hand-written copy of the `server_version` injection line (plan:670-675). The plan itself acknowledges this is "intentionally a duplicate" (plan:681). If the production injection logic changes (e.g. moved into `encode_response_body` per CRITICAL-2) but the test double isn't updated, the test still passes — false-negative TDD coverage. The two `test_write_response_injects_*` tests verify only that the double behaves as written, not that production code does.

**OPTIONS:**
1. **Rewrite `make_server_double` to invoke the real `write_response` with a captured-write fake socket** — production code runs; test asserts real injection (рекомендуется).
2. **Add a separate integration test that does NOT override `write_response`** — keeps the double for other purposes; explicit production verification.
3. **Replace the double with method-level isolation: extract the injection into `Compat.inject_server_version(response)` and test that helper directly** — cleanest but adds a tiny indirection layer.

---

### [CONCERN-2] Notifications + version-mismatch behavior undefined
**SOURCES:** codex, kimi (CI-3), deepseek (#14) — **3/5 reviewers**
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** Acceptance criterion in design §15 says "Ruby returns a JSON-RPC error with code -32001 for every method except get_version" (design:663). But Ruby's existing dispatch correctly *does not respond* to notifications (no `id` key) — `dispatch.rb:42`. The design does not specify what happens on a version-mismatch notification: should the check still run, should errors be logged, should the response be suppressed? Plan's current code path would send `id: nil` error responses for notification mismatches (related to CRITICAL-1).

**OPTIONS:**
1. **Document explicitly: notifications with version-mismatch are logged WARN-level and silently dropped (no response, per JSON-RPC 2.0 spec)** (рекомендуется) — matches existing notification semantics; one line in design §6 and one in plan Task 4.3.
2. **Run version-check on notifications too but ensure no response is written** — same behavior; explicit code path.
3. **Skip version-check entirely for notifications** — simpler but allows incompatible plugins to silently send notifications.

---

### [CONCERN-3] `RUBY_VERSION` constant shadows Ruby's global `::RUBY_VERSION`
**SOURCES:** ccs-glm (C3) — **1/5 reviewers** (single-source but well-justified)
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** Plan Task 3 creates `SU_MCP::Core::Compat::RUBY_VERSION` (plan:32, design:347). Inside the `Compat` module, a bare reference to `RUBY_VERSION` resolves to the plugin version, not the global Ruby interpreter version. A future contributor adding diagnostic code inside `Compat` that needs the interpreter version would silently get the wrong value with no warning. The name is also semantically misleading — it's the plugin's version, not Ruby's.

**OPTIONS:**
1. **Rename to `PLUGIN_VERSION` (and the Python mirror to `PLUGIN_VERSION` too)** (рекомендуется) — symmetrical; clearly distinct from `::RUBY_VERSION`; touches a handful of files.
2. **Rename to `SERVER_VERSION` (matches the wire-field name `server_version`)** — also clear; aligns with the protocol.
3. **Keep `RUBY_VERSION` but add a comment warning about shadowing** — least change; mine remains for future readers.

---

### [CONCERN-4] `_parse` reparses MIN/MAX constants on every check call
**SOURCES:** ccs-glm (W6) — **1/5 reviewers**
**SEVERITY:** Concern (micro-perf / cleanliness)
**STATUS:** NEW

**BODY:** `check_ruby_version` and `check_python_version` invoke `_parse(MIN_RUBY)` and `_parse(MAX_RUBY)` on every call (plan:240-243). The cost is microseconds, but since constants don't change, this is wasted work — and more importantly, makes monkey-patching MIN/MAX in tests work only because parse is re-run. Reusing pre-parsed tuples would make the constants more clearly "frozen at module load".

**OPTIONS:**
1. **Leave as-is** (рекомендуется) — cost is negligible (~microseconds); flexibility benefits tests; consistent with existing pattern.
2. **Cache parsed tuples in module-level `_MIN_RUBY_TUPLE`, `_MAX_RUBY_TUPLE`** — micro-optimization; breaks monkeypatch-based tests unless they patch the cache too.
3. **Add a `_refresh()` helper for tests to call after monkey-patching** — explicit but adds API surface.

---

### [CONCERN-5] Asymmetric error class on the Python side at version-mismatch
**SOURCES:** codex (in Concerns), minimax (#6) — **2/5 reviewers**
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** When Python detects mismatch via `check_ruby_version`, it raises `IncompatibleVersionError`. But when Ruby detects mismatch and sends back a `-32001` JSON-RPC error, `_send_once` converts it to a generic `SketchUpError(-32001, ...)` — not `IncompatibleVersionError`. The user-visible message text is right, but log-grep, error-class filtering in `try/except IncompatibleVersionError`, and any conditional retry logic differ between the two directions. Additionally, the `disconnect()` call on any JSON-RPC error tears down the socket on the Ruby-detected case (deepseek #7).

**OPTIONS:**
1. **In `_send_once`, when the inbound error has code `-32001`, raise `IncompatibleVersionError` instead of `SketchUpError`** (рекомендуется) — symmetric error class; preserves message; clean catch in callers.
2. **Make `IncompatibleVersionError` a subclass of `SketchUpError` (already is per design §7.2) and rely on isinstance checks** — already true; not actionable on its own.
3. **Suppress `disconnect()` on `-32001` errors** — protects long-lived sessions but couples error handling to transport.

---

### [CONCERN-6] Hard-fail per request is verbose without a hint pointing to `get_version`
**SOURCES:** codex (Hard-fail on MCP-границе), kimi (C-6) — **2/5 reviewers**
**SEVERITY:** Concern (UX)
**STATUS:** NEW

**BODY:** Every tool call on a mismatched setup produces an error message. In Claude Desktop, a user calling several tools sees a wall of nearly-identical errors. None of them suggest "call `get_version` to inspect the state". Additionally, the inside `connection.py` raises, but text-tools via `_call` catch `SketchUpError` and return a formatted string instead of a true MCP tool error (tools.py:57) — the UX is "user-visible string" rather than a structured MCP error envelope.

**OPTIONS:**
1. **Append "Call `get_version` for details." to each `IncompatibleVersionError` message** (рекомендуется) — one-line change in three message helpers; cheap discoverability.
2. **Convert `IncompatibleVersionError` into a true MCP tool error envelope instead of a wrapped string** — better protocol-level UX but larger change; risk of behavior drift.
3. **Cache the first mismatch and suppress duplicates within a session** — reduces noise but hides the issue across multiple ad-hoc invocations.

---

### [CONCERN-7] `MIN_*` and `MAX_*` both set to `0.0.3` is exact-match, not a range
**SOURCES:** kimi (C-1) — **1/5 reviewers**
**SEVERITY:** Concern (policy clarity)
**STATUS:** NEW

**BODY:** Design and plan set `MIN_RUBY = MAX_RUBY = "0.0.3"` initially (plan:211-212). Until either is bumped, even a 0.0.4 plugin is rejected as "too new". After 1.0.0, if the policy stays "MIN==MAX", every patch release across the wire pair will reject every other release. The design does not specify when MIN moves vs when only MAX moves. `docs/release.md` §1 will say "bump all 7 places" but doesn't specify the policy.

**OPTIONS:**
1. **Document policy in design §13 (Open decisions) AND in release.md: "MAX_* always tracks the latest release; MIN_* bumps only when wire/handler contract breaks"** (рекомендуется) — matches design §10 hint; one paragraph.
2. **Use semver range "any version with same MAJOR/MINOR" as initial policy** — friendlier defaults; but requires semver dependency.
3. **Leave undocumented for now and decide at 1.0.0 release** — defers the decision but invites repeat questions.

---

### [CONCERN-8] Lenient version parser accepts whitespace/sign forms
**SOURCES:** codex (Парсер версий мягче, чем заявлено) — **1/5 reviewers**
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** Both Python `int(...)` and Ruby `Integer(...)` accept lots of forms beyond `X.Y.Z` numeric — e.g. leading/trailing whitespace in parts, optional sign (`+1`), underscores in Ruby (`1_0`). Design §3 says "Tuple comparison on (major, minor, patch) only. Versions outside that shape are invalid input" (design:54-56). The parser doesn't enforce this.

**OPTIONS:**
1. **Validate parts against `\A\d+\z` regex on both sides before integer conversion** (рекомендуется) — strict shape; one line per side; consistent with stated contract.
2. **Document the lenient behavior as accepted** — matches current code; weakens spec.
3. **Use a strict semver library** — overkill; introduces dependency.

---

### [CONCERN-9] `client_version` injection bypassed by hypothetical alt-sender path
**SOURCES:** codex, ccs-glm (W3) — **2/5 reviewers**
**SEVERITY:** Concern
**STATUS:** NEW

**BODY:** Design §7.3 defines `skip_version_check` as a keyword argument on `_raw_call`. Plan Task 6 drops the keyword and instead checks `if name != "get_version"` inside `_send_once` (plan:1086-1088). This is simpler, but it creates a hidden coupling: anyone bypassing `_raw_call` (e.g. a future direct caller of `_send_once`) won't get the implicit bypass. Risk §14 in the design notes this for `client_version` injection; doesn't note it for the bypass.

**OPTIONS:**
1. **Keep the name-based bypass but document the rule in connection.py and tools.py: "if you add a new sender, route it through `_raw_call` so handshake logic is consistent"** (рекомендуется).
2. **Adopt the design's `skip_version_check` keyword** — explicit at the call-site; slightly more boilerplate.
3. **Make the bypass a dispatch-table lookup (`if name in _BYPASS_COMPAT_TOOLS:`)** — extensible if more diagnostics arrive.

---

### [CONCERN-10] `response` may not be a `dict` before `check_ruby_version` call
**SOURCES:** minimax (#4) — **1/5 reviewers**
**SEVERITY:** Concern (robustness)
**STATUS:** NEW

**BODY:** Plan Task 6.3(c) calls `compat.check_ruby_version(response.get("server_version"))` after `response = json.loads(response_body)`. If a malformed plugin response sends a JSON array/string at the top level, `response.get(...)` raises `AttributeError` before the compat check. Unlikely in practice (existing id-match check at lines 188-192 should already catch this), but worth defensive coverage.

**OPTIONS:**
1. **Assume the existing envelope validation upstream catches non-dict responses; add a one-line assertion `assert isinstance(response, dict)` to make the assumption explicit** (рекомендуется).
2. **Wrap the version-check with `if isinstance(response, dict):`** — defensive; silently skips check on weird input.
3. **Raise a dedicated `MalformedResponseError`** — best UX but new exception class.

---

### [CONCERN-11] `client_version` adds ~20 bytes to payload before size-check
**SOURCES:** kimi (C-7) — **1/5 reviewers**
**SEVERITY:** Concern (minor)
**STATUS:** NEW

**BODY:** Every request now carries `"client_version": "0.0.3"` (~25 bytes). The framing layer enforces a 64 MiB cap — 25 extra bytes will never matter in practice. Worth a note if the size check is calculated *before* version injection somewhere (it isn't, but plan and design don't explicitly address it).

**OPTIONS:**
1. **Note in design §6 that the version fields are accounted for inside the 64 MiB cap; no further action** (рекомендуется).
2. **Add a test that asserts the cap still triggers with version-field present** — over-engineering for 25 bytes.

---

### [CONCERN-12] `remove_const`/`const_set` test pattern is brittle
**SOURCES:** deepseek (#6) — **1/5 reviewers**
**SEVERITY:** Concern (test infra)
**STATUS:** NEW

**BODY:** Plan Task 4.1's `test_dispatch_with_incompatible_client_version_*` mutates `SU_MCP::Core::Compat::MIN_PYTHON` via `remove_const`/`const_set` (plan:594-601). If an exception fires between `remove_const` and the test body, the `ensure` clause will try to `remove_const` a constant that no longer exists. Ruby will emit "already initialized constant" warnings on each test run.

**OPTIONS:**
1. **Use `RbConfig`-style indirection: have `check_python_version` accept optional `min:`/`max:` keyword args, default to constants; tests pass overrides directly** (рекомендуется) — clean; no constant mutation.
2. **Wrap mutation in a helper `with_compat_range(min, max) { ... }`** that handles teardown safely — explicit; matches existing patterns.
3. **Leave as-is** — already works; warnings are cosmetic.

---

### [CONCERN-13] `test_python_version_is_imported_from_init` is weak
**SOURCES:** deepseek (#8) — **1/5 reviewers**
**SEVERITY:** Concern (test rigor)
**STATUS:** NEW

**BODY:** The test asserts `compat.PYTHON_VERSION == __version__` (plan:184-187), but doesn't verify *import-time* binding. A future refactor that hard-codes `"0.0.3"` in `compat.py` would silently still pass the test as long as `__init__.py` also has `"0.0.3"`. The test doesn't catch the regression it's named to catch.

**OPTIONS:**
1. **Add a second assertion that monkey-patches `__version__` and re-imports `compat`, verifying `PYTHON_VERSION` changes** (рекомендуется) — actually proves the binding.
2. **Check `compat.__dict__["PYTHON_VERSION"] is __version__` (identity, not equality)** — Python strings aren't always interned, fragile.
3. **Leave as-is, rename to `test_python_version_matches_init`** — honest naming; weaker test.

---

### [SUGGESTION-1] Single compat table source (JSON file shared by both sides)
**SOURCES:** deepseek (#9) — **1/5 reviewers**
**SEVERITY:** Suggestion (out-of-scope but worth listing)
**STATUS:** NEW

**BODY:** Risk of split-version bumps (one side bumps, the other doesn't) is mitigated only by `docs/release.md` discipline. A shared JSON file (`compat.json`) read by both sides at startup would eliminate the duplication risk at the cost of an extra file-read on Ruby boot. Design §12 explicitly defers this ("Yet another file to bump in sync; would also require runtime JSON-parse from inside the Ruby plugin on every connect"), but the deferral could be revisited.

**OPTIONS:**
1. **Confirm "out of scope" stance in design §12 and update plan to refer to it for any future "why not JSON?" questions** (рекомендуется).
2. **Adopt the shared JSON approach** — bigger change; reopens design.
3. **Document a CI check that asserts MIN/MAX match across both files** — middle ground; catches drift mechanically.

---

### [SUGGESTION-2] Add explicit test: `MAX_RUBY == PYTHON_VERSION` and `MAX_PYTHON == RUBY_VERSION`
**SOURCES:** ccs-glm (S4), kimi (S-5), minimax (#9 implicit) — **3/5 reviewers**
**SEVERITY:** Suggestion
**STATUS:** NEW

**BODY:** Implicit invariant: when releasing version N, MAX_RUBY should equal N and MAX_PYTHON should equal N. Without an automated check, a release with mismatched MAX_* won't be caught until smoke tests. A simple unit test on both sides would catch this at commit time.

**OPTIONS:**
1. **Add `test_max_ruby_matches_python_version` and `test_max_python_matches_ruby_version` to `test_compat.py`/`test_compat.rb`** (рекомендуется) — one-line tests; cheap insurance.
2. **Add the check to `docs/release.md` Section 1 as a manual verification step** — works but easy to forget.
3. **Leave as-is** — risk acceptance.

---

### [SUGGESTION-3] Test for `server_version` present in fallback (encoding-failure) response
**SOURCES:** kimi (S-6), minimax (#12 question) — **2/5 reviewers**
**SEVERITY:** Suggestion
**STATUS:** NEW

**BODY:** If CRITICAL-2 is fixed by moving the injection into `encode_response_body`, there should be a direct test that monkey-patches `JSON.generate` to raise `JSON::GeneratorError`, then asserts the fallback envelope contains `server_version`. The current `make_server_double` only covers the success path.

**OPTIONS:**
1. **Add `test_write_response_includes_server_version_on_json_generator_error` to `test_server_compat.rb`** (рекомендуется) — directly verifies CRITICAL-2 fix.
2. **Cover indirectly via an integration test with a giant payload that forces fallback** — flaky and slow.

---

### [SUGGESTION-4] Remove duplicate `method = request["method"]` assignment
**SOURCES:** ccs-glm (W4, S6) — **1/5 reviewers**
**SEVERITY:** Suggestion
**STATUS:** NEW

**BODY:** Plan Task 4.3 inserts `method = request["method"]` at line 706, but the existing dispatch.rb code at line 17 already has the same assignment. Result: the variable is set twice (the second overwrite is a no-op). Plan should either remove the new assignment (let the existing one survive) or remove the existing one.

**OPTIONS:**
1. **Drop the new `method = request["method"]` line; reference the existing variable** (рекомендуется) — minimal diff; depends on Task 4.3 also moving the assignment if reorder per CRITICAL-1.
2. **Keep both; document as harmless duplication** — code smell.
3. **Move all variable extraction into a `parse_request_envelope(request)` helper** — cleaner refactor; out of scope.

---

### [SUGGESTION-5] Document design→plan divergences explicitly
**SOURCES:** codex, ccs-glm (S7) — **2/5 reviewers**
**SEVERITY:** Suggestion
**STATUS:** NEW

**BODY:** Plan made several improvements over design (bypass check location moved from server.rb to dispatch.rb; wire format corrected from `method != "get_version"` to `params.name == "get_version"`) without acknowledging the divergences. A future reader comparing the two documents will be confused. Either align design to plan (best) or annotate the differences in plan ("DEPARTURE FROM DESIGN: ...").

**OPTIONS:**
1. **Update design §8.2 and §6 to match plan (best target) and add a "Changelog vs. brainstorming notes" subsection at top of plan listing the deltas** (рекомендуется).
2. **Add inline "Departure from design" callouts in plan only** — design stays out-of-date.
3. **Add a clarifying section "What changed during planning" at top of plan** — same as option 1 minus the design update.

---

### [SUGGESTION-6] Consistent test filename: `test_server.rb` vs `test_server_compat.rb`
**SOURCES:** deepseek (#12) — **1/5 reviewers**
**SEVERITY:** Suggestion (naming)
**STATUS:** NEW

**BODY:** Design §9.2 mentions `test_server.rb`; plan creates `test_server_compat.rb`. Other Ruby tests (`test_dispatch.rb`, `test_view.rb`) use the bare-name convention. Choose one and reflect it everywhere.

**OPTIONS:**
1. **Keep `test_server_compat.rb` (more descriptive) and update design accordingly** (рекомендуется) — current plan naming wins; design follows.
2. **Rename to `test_server.rb`** — matches naming style; risks conflict with future general server tests.
3. **Use `test_handshake.rb` (parallel to Python's `test_version_handshake.py`)** — most symmetric; rename touches plan only.

---

### [SUGGESTION-7] Add the missing `test_get_version_works_when_other_tools_blocked` test
**SOURCES:** kimi (C-3) — **1/5 reviewers**
**SEVERITY:** Suggestion
**STATUS:** NEW

**BODY:** Design §9.1 lists `test_get_version_works_when_other_tools_blocked` as a required test (design:495), but plan Task 7's test list does not include it (plan:1133-1233). The test would verify the end-to-end bypass: with `MIN/MAX` patched so ordinary tools fail, `get_version` still returns a useful payload via the `skip_version_check`/name-based bypass.

**OPTIONS:**
1. **Add the test to plan Task 7.1's test list** (рекомендуется) — closes the design→plan gap.
2. **Remove it from design §9.1 and replace with existing tests** — weaker coverage.
3. **Mark it as integration-only and move to smoke check** — covered by Task 8 but not unit-tested.

---

### [QUESTION-1] What does `compatible` mean in `get_version`: one-way Python check, or two-way both ranges accept?
**SOURCES:** codex — **1/5 reviewers**
**SEVERITY:** Question
**STATUS:** NEW

**BODY:** Plan Task 7's `get_version` computes `compatible` only via Python's `check_ruby_version(ruby_version)` — it does NOT check that Ruby's advertised `min_compatible_python..max_compatible_python` accepts `PYTHON_VERSION` (plan:1279-1283). If the two compat tables drift (e.g. Python says `MIN_RUBY=0.1.0` but Ruby says `MAX_PYTHON=0.0.9`), `get_version` may report compatible=true while ordinary tool calls hard-fail.

**OPTIONS:**
1. **Check both directions: `compatible = python_accepts_ruby AND ruby_advertised_range_accepts_python_version`** (рекомендуется) — actual diagnostic; consistent with payload fields.
2. **Keep one-way check, but expose `ruby_min_python`/`ruby_max_python` in the payload so users can see drift** — informative, lighter implementation.
3. **Add a second flag `ruby_accepts_python` distinct from `python_accepts_ruby`** — most explicit; UI shows both perspectives.

---

### [QUESTION-2] Should `get_version` return `dict` or JSON-string?
**SOURCES:** deepseek (#13), kimi (Q-3) — **2/5 reviewers**
**SEVERITY:** Question
**STATUS:** NEW

**BODY:** Design §7.4 shows `get_version` returning a `dict` (design:307). Plan Task 7.3 wraps the same payload in `json.dumps(...)` (plan:1267, 1284) — returns a `str`. Other typed tools in this codebase return dicts; FastMCP serializes them. Returning a stringified JSON in the tool means MCP UI displays raw JSON text in the response.

**OPTIONS:**
1. **Return `dict`, let FastMCP serialize** (рекомендуется) — consistent with all other tools; better UI rendering.
2. **Keep `json.dumps` return** — explicit text content; matches some smoke-check parsers.
3. **Make it configurable via parameter** — over-engineering.

---

### [QUESTION-3] Concurrent reconnect behavior on mismatch?
**SOURCES:** kimi (Q-2) — **1/5 reviewers**
**SEVERITY:** Question
**STATUS:** NEW

**BODY:** Connection.py holds one persistent TCP socket with an `asyncio.Lock` serializing tool calls. If a version-mismatch causes `disconnect()`, the next call reconnects; two concurrent awaiters during the disconnect window could race. Probably handled by the existing lock, but the version-mismatch path was not in scope when the lock was added.

**OPTIONS:**
1. **Add a one-line note in plan Task 6.3: "The existing `asyncio.Lock` already serializes; no new locking needed; concurrent mismatches just see successive identical errors"** (рекомендуется).
2. **Add a multi-task concurrent-mismatch test** — defensive; rare scenario.
3. **Suppress reconnect on `-32001` to avoid churn** — protects sockets but breaks "every request rechecks".

---

### [QUESTION-4] Why `StructuredError(-32001)` instead of a dedicated Ruby exception?
**SOURCES:** kimi (Q-4) — **1/5 reviewers**
**SEVERITY:** Question
**STATUS:** NEW

**BODY:** Python side has a dedicated `IncompatibleVersionError(SketchUpError)` subclass. Ruby side reuses generic `Core::StructuredError(-32001, ...)`. Asymmetric. A dedicated `Compat::IncompatibleVersionError` would allow Ruby callers to `rescue` specifically and would parallel Python.

**OPTIONS:**
1. **Add `Core::IncompatibleVersionError < StructuredError` on Ruby side**, set code=-32001 in initialize (рекомендуется) — symmetric API.
2. **Leave as-is** — fewer files; relies on the code constant.
3. **Drop the Python subclass too, use generic exceptions both sides** — removes the asymmetry by leveling down.

---

## SUMMARY

**total:** 31
**new:** 31
**repeated:** 0

### By severity:
- **CRITICAL:** 7 (CRITICAL-1 .. CRITICAL-7)
- **CONCERN:** 13 (CONCERN-1 .. CONCERN-13)
- **SUGGESTION:** 7 (SUGGESTION-1 .. SUGGESTION-7)
- **QUESTION:** 4 (QUESTION-1 .. QUESTION-4)

### Consensus issues (raised by 3+ reviewers — highest priority):
- **CRITICAL-1** `request_id = nil` in rescue at version-mismatch — **4 reviewers** (codex, ccs-glm, kimi, deepseek)
- **CRITICAL-2** `server_version` lost in encoding fallback — **4 reviewers** (codex, ccs-glm, kimi, minimax)
- **CRITICAL-3** `get_version` doesn't catch `SketchUpError` — **4 reviewers** (codex, ccs-glm, kimi, deepseek)
- **CRITICAL-4** `get_version` absent from `_RETRY_SAFE_TOOLS` — **4 reviewers** (codex, ccs-glm, kimi, deepseek)
- **CRITICAL-5** Wire-level bypass design contradicts plan — **4 reviewers** (codex, ccs-glm, minimax, deepseek)
- **CONCERN-1** Test double duplicates production logic — **4 reviewers** (codex, ccs-glm, kimi, minimax)
- **CONCERN-2** Notifications + version-mismatch undefined — **3 reviewers** (codex, kimi, deepseek)
- **SUGGESTION-2** Add `MAX_RUBY == PYTHON_VERSION` invariant test — **3 reviewers** (ccs-glm, kimi, minimax)

### Two-reviewer consensus:
- **CRITICAL-6** Task 4/5 hidden dependency (codex, deepseek)
- **CRITICAL-7** `test_connection.py` will break after Task 6 (codex, ccs-glm)
- **CONCERN-5** Asymmetric error class Python vs Ruby (codex, minimax)
- **CONCERN-6** Hard-fail lacks hint to `get_version` (codex, kimi)
- **CONCERN-9** `client_version` injection alt-sender path (codex, ccs-glm)
- **SUGGESTION-3** Test for `server_version` in fallback (kimi, minimax)
- **SUGGESTION-5** Document design→plan divergences (codex, ccs-glm)
- **QUESTION-2** dict vs JSON-string return (deepseek, kimi)

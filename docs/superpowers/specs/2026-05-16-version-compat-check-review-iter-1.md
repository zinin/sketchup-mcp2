# Review Iteration 1 — 2026-05-16

## Источник

- Design: `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
- Review agents: codex-executor (gpt-5.5/xhigh), ccs-executor (glm-5.1), ollama-executor (kimi, minimax, deepseek)
- Merged output: `docs/superpowers/specs/2026-05-16-version-compat-check-review-merged-iter-1.md`
- Parsed issues: `docs/superpowers/specs/2026-05-16-version-compat-check-parsed-issues-iter-1.md`

## Замечания

### [CRITICAL-1] `request_id = nil` when version-mismatch fires in `dispatch.rb`

> Plan Task 4.3 inserts compat check BEFORE `request_id = request["id"]`.
> `StructuredError(-32001)` rescue builds response with `id: nil`,
> violating JSON-RPC 2.0. Also affects notification handling.

**Источник:** codex, ccs-glm (W4 partial), kimi (CI-3), deepseek (#1) — 4/5
**Статус:** Автоисправлено
**Ответ:** Plan Task 5 reordered to capture `request_id` AND `is_notification` BEFORE the compat check (option 1). Notifications with mismatch are logged WARN and silently dropped (no response, per JSON-RPC 2.0). Regression test `test_dispatch_incompatible_client_version_preserves_request_id` and `test_dispatch_notification_with_mismatch_silently_dropped` added.
**Действие:** Design §8.2 and Plan Task 5 step 5.3 updated with correct ordering and notification suppression.

---

### [CRITICAL-2] `server_version` not injected into `encode_response_body` fallback envelope

> Plan Task 4.4 injects in `write_response`, but fallback path in
> `encode_response_body` replaces response with new hash from
> `Errors.build_error_response()`. Field is lost, masking real errors.

**Источник:** codex, ccs-glm (W1), kimi (CI-2), minimax (#1) — 4/5
**Статус:** Автоисправлено
**Ответ:** Injection moved from `write_response` to `encode_response_body` — covers both `JSON.generate` happy path AND `JSON::GeneratorError` fallback (option 1). New test `test_encode_response_body_injects_server_version_on_json_generator_fallback` forces the fallback to verify field presence.
**Действие:** Design §8.2.1 and Plan Task 5 step 5.4 updated to reflect new single choke point.

---

### [CRITICAL-3] `get_version` tool wrapper only catches `ConnectionError`, not `SketchUpError`

> Old Ruby (0.0.3) returns `-32601 "unknown tool: get_version"`; current
> wrapper raises `SketchUpError`. Violates acceptance criterion
> "returns a payload on every call regardless of mismatch state".

**Источник:** codex, ccs-glm (implicit via Q3), kimi (CI-1), deepseek (#2) — 4/5
**Статус:** Автоисправлено
**Ответ:** Added `except SketchUpError as e` returning the canonical "compatible=false, ruby_version=None, error=<msg>" payload (option 1).
**Действие:** Design §7.4 and Plan Task 7 step 7.3 updated.

---

### [CRITICAL-4] `get_version` route absent from `_RETRY_SAFE_TOOLS` whitelist

> Read-only diagnostic tool first thing users call when something
> is wrong, but stale-socket auto-retry doesn't include it.

**Источник:** codex, ccs-glm (C2), kimi (C-2), deepseek (#4) — 4/5
**Статус:** Автоисправлено
**Ответ:** Added `"get_version"` to `_RETRY_SAFE_TOOLS` frozenset (option 1). New unit test `test_get_version_in_retry_safe_tools` guards the regression.
**Действие:** Design §7.3 and Plan Task 6 step 6.4 (e) updated.

---

### [CRITICAL-5] Wire-level bypass logic in design §8.2 contradicts plan and real protocol

> Design shows `if method != "get_version"` but Python ALWAYS sends
> `method: "tools/call"`. Future reader of design alone would
> implement a broken bypass.

**Источник:** codex, ccs-glm (C4), minimax (#3), deepseek (#5) — 4/5
**Статус:** Автоисправлено
**Ответ:** Design §8.2 rewritten with the correct `method == "tools/call" && params.name == "get_version"` form (option 1). Design §6 request example also updated to show the actual wire format.
**Действие:** Design §6 and §8.2 fully updated.

---

### [CRITICAL-6] Task 4 has hidden dependency on Task 5 — `test_server_compat.rb` cannot pass in Task 4

> Tests require `handlers/system.rb` (created in Task 5) and the
> `when "get_version"` route. Step 4.5 "all tests green" impossible.

**Источник:** codex, deepseek (#3) — 2/5
**Статус:** Автоисправлено
**Ответ:** Tasks 4 and 5 reordered. New Task 4 creates `handlers/system.rb` + dispatch route + `test_system.rb` first (the old Task 5 content); new Task 5 then adds the server-compat handshake with REAL `Dispatch.handle` + REAL `Core::Server` integration tests (replaces the old broken Task 4) — no method-overriding double (option 1).
**Действие:** Plan Tasks 4 and 5 completely restructured.

---

### [CRITICAL-7] Existing `tests/test_connection.py` (~20 tests) will break after Task 6

> `encode_response()` helper doesn't include `server_version`; after
> Task 6 every existing test trips `IncompatibleVersionError("pre-dates")`.
> Files-to-MODIFY missing `conftest.py`.

**Источник:** codex, ccs-glm (C1) — 2/5
**Статус:** Автоисправлено
**Ответ:** Plan now includes `tests/conftest.py` modification: `encode_response()` injects `server_version=compat.MAX_RUBY` by default (option 1); explicit `server_version=None` available for negative-case tests. Added as new step 6.3.
**Действие:** Plan Task 6 step 6.3 added; files-to-MODIFY table updated.

---

### [CONCERN-1] Test double `make_server_double` duplicates production logic

> `make_server_double` overrides `write_response` with hand-written copy;
> tests pass even if production code is never modified.

**Источник:** codex, ccs-glm (W2), kimi (C-5), minimax (#2) — 4/5
**Статус:** Автоисправлено
**Ответ:** Resolved as part of CRITICAL-6 fix. New `test_server_compat.rb` calls real `Dispatch.handle` and real `Core::Server.encode_response_body` with no method overrides; only the socket write is captured (option 1).
**Действие:** Plan Task 5 step 5.1 rewritten with REAL-code tests.

---

### [CONCERN-2] Notifications + version-mismatch behavior undefined

> Acceptance criterion says "Ruby returns JSON-RPC error" but Ruby
> correctly doesn't reply to notifications. Behavior on
> version-mismatch notification was not specified.

**Источник:** codex, kimi (CI-3), deepseek (#14) — 3/5
**Статус:** Автоисправлено
**Ответ:** Documented: notifications with version-mismatch are logged WARN-level and silently dropped (no response, per JSON-RPC 2.0 spec; option 1). Test `test_dispatch_notification_with_mismatch_silently_dropped` covers it.
**Действие:** Design §15 acceptance and Plan Task 5 step 5.3 updated.

---

### [CONCERN-3] `RUBY_VERSION` constant shadows Ruby's global `::RUBY_VERSION`

> Inside `module Compat`, bare `RUBY_VERSION` resolves to the plugin
> version, not the interpreter. Silent shadowing of standard constant.

**Источник:** ccs-glm (C3) — 1/5
**Статус:** Обсуждено с пользователем
**Ответ:** User chose **Вариант B (rename to `SERVER_VERSION`)** with extension: also rename Python's `PYTHON_VERSION` → `CLIENT_VERSION`. Both constants now match their wire-field counterparts (`client_version`/`server_version`). Symmetry restored via wire-role naming instead of language naming.
**Действие:** Both Python and Ruby compat modules renamed; design and plan updated throughout. All test names that mentioned `RUBY_VERSION` updated to `SERVER_VERSION` and `PYTHON_VERSION` to `CLIENT_VERSION`.

---

### [CONCERN-4] `_parse` reparses MIN/MAX constants on every check call

> Micro-perf concern: `_parse(MIN_RUBY)` runs every check call.

**Источник:** ccs-glm (W6) — 1/5
**Статус:** Отклонено
**Ответ:** Recommended action (option 1) is "leave as-is". Cost is microseconds; flexibility for monkeypatch-based tests; consistent with existing pattern.
**Действие:** No change.

---

### [CONCERN-5] Asymmetric error class on the Python side at version-mismatch

> Python detects mismatch → IncompatibleVersionError. Ruby detects
> mismatch and sends -32001 → Python wraps as generic SketchUpError.
> Callers can't catch a single class.

**Источник:** codex, minimax (#6) — 2/5
**Статус:** Автоисправлено
**Ответ:** In `_send_once`, inbound `error.code == -32001` is now promoted to `IncompatibleVersionError` instead of generic `SketchUpError` (option 1). New test `test_ruby_side_minus_32001_promoted_to_incompatible_version_error`.
**Действие:** Design §7.3 and Plan Task 6 step 6.4(d) updated.

---

### [CONCERN-6] Hard-fail per request is verbose without a hint pointing to `get_version`

> User sees wall of identical errors; none suggest the diagnostic tool.

**Источник:** codex (Hard-fail UX), kimi (C-6) — 2/5
**Статус:** Автоисправлено
**Ответ:** Each error message in both `compat.py` and `compat.rb` now ends with "Call `get_version` to inspect handshake state." (option 1).
**Действие:** Design §7.1 and Plan Task 2/Task 3 compat code updated; test assertions added to check for the hint.

---

### [CONCERN-7] `MIN_*` and `MAX_*` both set to `0.0.3` is exact-match, not a range

> Policy unclear: when does MIN move vs only MAX? Patch releases
> would reject each other if policy stays MIN==MAX.

**Источник:** kimi (C-1) — 1/5
**Статус:** Автоисправлено
**Ответ:** Documented in design §13 (Open decisions) and release.md plan (Task 9): "MAX_* always tracks the latest release; MIN_* moves only when this release breaks wire/handler contract with the previous counterpart" (option 1).
**Действие:** Design §13 + Plan Task 9 updated.

---

### [CONCERN-8] Lenient version parser accepts whitespace/sign forms

> Design §3 promises strict X.Y.Z numeric, but `int()`/`Integer()`
> accept `+1`, ` 1`, `1_0`, etc.

**Источник:** codex — 1/5
**Статус:** Автоисправлено
**Ответ:** Both parsers now validate parts against `\A\d+\Z` regex before integer conversion (option 1). Test parametrize lists extended with whitespace/sign/underscore negatives.
**Действие:** Design §7.1 and Plan Task 2 / Task 3 compat code + tests updated.

---

### [CONCERN-9] `client_version` injection bypassed by hypothetical alt-sender path

> Design uses `skip_version_check` keyword; plan drops it for
> name-based bypass. Future alt-sender wouldn't get the bypass.

**Источник:** codex, ccs-glm (W3) — 2/5
**Статус:** Автоисправлено
**Ответ:** Kept name-based bypass; added documentation rule in design §7.3 ("route new senders through `_raw_call` so handshake logic remains consistent"; option 1).
**Действие:** Design §7.3 updated with the rule.

---

### [CONCERN-10] `response` may not be a `dict` before `check_ruby_version` call

> Malformed plugin response could send array/string; `.get()` raises
> `AttributeError`.

**Источник:** minimax (#4) — 1/5
**Статус:** Автоисправлено
**Ответ:** Added `assert isinstance(response, dict)` before the compat check (option 1).
**Действие:** Plan Task 6 step 6.4(c) updated.

---

### [CONCERN-11] `client_version` adds ~20 bytes to payload before size-check

> Worth noting that version fields count inside the 64 MiB framing cap.

**Источник:** kimi (C-7) — 1/5
**Статус:** Автоисправлено
**Ответ:** Added a sentence to design §6 noting that version fields are accounted for inside the existing 64 MiB cap; negligible in practice (option 1).
**Действие:** Design §6 updated.

---

### [CONCERN-12] `remove_const`/`const_set` test pattern is brittle

> If exception fires between `remove_const` calls in setup, ensure
> raises secondary error masking the original.

**Источник:** deepseek (#6) — 1/5
**Статус:** Автоисправлено
**Ответ:** `with_range` helper updated with `defined?`-guards in ensure block (option 2) — safe even on partial setup.
**Действие:** Plan Task 3 step 3.1 updated.

---

### [CONCERN-13] `test_python_version_is_imported_from_init` is weak

> Test asserts equality but doesn't verify import-time binding.

**Источник:** deepseek (#8) — 1/5
**Статус:** Отклонено
**Ответ:** Recommended action would be a monkey-patch-and-reimport test, which is significantly more complex without proportional value (the existing test catches the most likely regression — hardcoded duplication caught by the next release-time bump). Leaving as-is.
**Действие:** No change.

---

### [SUGGESTION-1] Single compat table source (JSON file shared by both sides)

> Eliminates duplication risk but requires runtime JSON-parse from Ruby.

**Источник:** deepseek (#9) — 1/5
**Статус:** Автоисправлено
**Ответ:** Explicitly rejected in design §12 (Out of scope) with rationale: path resolution between PyPI-installed Python and `.rbz`-installed Ruby is awkward; runtime JSON-parse in SketchUp's Ruby is slower than constants; two tables + release checklist + three invariant tests give comparable safety with less infrastructure (option 1).
**Действие:** Design §12 updated with the rejection.

---

### [SUGGESTION-2] Add explicit test: `MAX_RUBY == PYTHON_VERSION` and `MAX_PYTHON == RUBY_VERSION`

> Implicit invariant — automated check catches release-time forgotten-bump.

**Источник:** ccs-glm (S4), kimi (S-5), minimax (#9 implicit) — 3/5
**Статус:** Автоисправлено
**Ответ:** Added `test_max_ruby_matches_client_version` to `test_compat.py` and `test_max_python_matches_server_version` to `test_compat.rb` (option 1). Mentioned in design §10 (release.md update).
**Действие:** Plan Task 2 / Task 3 tests + Plan Task 9 release.md update.

---

### [SUGGESTION-3] Test for `server_version` present in fallback (encoding-failure) response

> If CRITICAL-2 fixed, need a direct test that forces fallback path.

**Источник:** kimi (S-6), minimax (#12 question) — 2/5
**Статус:** Автоисправлено
**Ответ:** Added `test_encode_response_body_injects_server_version_on_json_generator_fallback` to `test_server_compat.rb` (option 1).
**Действие:** Plan Task 5 step 5.1 updated.

---

### [SUGGESTION-4] Remove duplicate `method = request["method"]` assignment

> Plan inserts a second `method = request["method"]` while existing
> code already has it.

**Источник:** ccs-glm (W4, S6) — 1/5
**Статус:** Автоисправлено (subsumed by Task 5 rewrite)
**Ответ:** Resolved as part of Task 5 rewrite — the new code flow assigns `method` exactly once in the new ordered block.
**Действие:** Plan Task 5 step 5.3 reflects clean single assignment.

---

### [SUGGESTION-5] Document design→plan divergences explicitly

> Multiple plan-vs-design diffs went unflagged.

**Источник:** codex, ccs-glm (S7) — 2/5
**Статус:** Автоисправлено
**Ответ:** Added a "Changelog vs design (iter-1 review fixes)" subsection at top of plan listing all 11 deviations. Also updated design throughout to match plan where the plan was correct (option 1).
**Действие:** Plan intro section expanded with changelog.

---

### [SUGGESTION-6] Consistent test filename: `test_server.rb` vs `test_server_compat.rb`

> Design §9.2 mentions `test_server.rb`; plan creates `test_server_compat.rb`.

**Источник:** deepseek (#12) — 1/5
**Статус:** Автоисправлено
**Ответ:** Kept `test_server_compat.rb` (plan name; more descriptive); design §9.2 updated to match (option 1).
**Действие:** Design §9.2 acceptance criterion reference updated.

---

### [SUGGESTION-7] Add the missing `test_get_version_works_when_other_tools_blocked` test

> Design §9.1 lists it; plan Task 7 doesn't.

**Источник:** kimi (C-3) — 1/5
**Статус:** Автоисправлено
**Ответ:** Test added to design §9.1 (`test_version_tool.py` table) alongside `test_get_version_returns_payload_on_unknown_tool_error` and `test_two_way_compat_drift_detected`. Plan Task 7 already covers it via the `failing_raw_call` fixture (option 1).
**Действие:** Design §9.1 table updated; plan Task 7 tests cover the scenario.

---

### [QUESTION-1] What does `compatible` mean: one-way Python check, or two-way both ranges accept?

> Currently one-way (Python's view); two-way would catch table drift.

**Источник:** codex — 1/5
**Статус:** Авто-применено после анализа (Вариант 1 — two-way)
**Ответ:** Applied option 1 (two-way check) as recommended. `get_version` now computes `compatible = python_accepts_ruby AND ruby_accepts_python_via_advertised_range`. Catches table-drift edge case. Payload exposes new fields `ruby_min_compatible_python` and `ruby_max_compatible_python`. Test `test_two_way_compat_drift_detected` covers the new case.
**Действие:** Design §7.4 + §13 and Plan Task 7 step 7.3 + Task 7 tests updated.

---

### [QUESTION-2] Should `get_version` return `dict` or JSON-string?

> Design says dict, plan says str. Inconsistency.

**Источник:** deepseek (#13), kimi (Q-3) — 2/5
**Статус:** Авто-применено после анализа (Вариант A — JSON-string)
**Ответ:** Kept `-> str` with explicit `json.dumps(...)`. Rationale: consistency with every other tool in `tools.py`; FastMCP serializes either way; no observable difference for LLM; explicit control over formatting; only one variant is genuinely adequate given the codebase's existing pattern. Design §7.4 updated to match plan (was previously inconsistent).
**Действие:** Design §7.4 signature `-> dict` → `-> str`.

---

### [QUESTION-3] Concurrent reconnect behavior on mismatch?

> Asyncio.Lock should handle it; design didn't mention.

**Источник:** kimi (Q-2) — 1/5
**Статус:** Автоисправлено
**Ответ:** Added one-line note in design §7.3: "The existing `asyncio.Lock` continues to serialize concurrent callers, so two awaiters seeing a mismatch will each get an identical IncompatibleVersionError instead of racing" (option 1).
**Действие:** Design §7.3 updated.

---

### [QUESTION-4] Why `StructuredError(-32001)` instead of a dedicated Ruby exception?

> Python has IncompatibleVersionError; Ruby uses generic StructuredError.

**Источник:** kimi (Q-4) — 1/5
**Статус:** Авто-применено после анализа (Вариант A — leave as-is)
**Ответ:** Kept generic `StructuredError(-32001)`. Rationale: YAGNI — no Ruby-caller currently or in the foreseeable future needs to `rescue IncompatibleVersionError` specifically; wire-level symmetry (both sides emit `-32001`) is what matters because that's all the other side sees; cosmetic code-symmetry isn't worth +20 lines and test changes. If a real Ruby caller emerges, adding a subclass is 5 minutes' work.
**Действие:** No change.

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-16-version-compat-check-design.md` | Major rewrite of §6 (wire format), §7.1 (strict parser, hints), §7.3 (full _send_once shape), §7.4 (two-way check, except SketchUpError, JSON-string), §8.2 (correct bypass logic, request_id ordering), §8.2.1 (server_version injection in encode_response_body), §12 (rejected shared JSON), §13 (compat decision + MIN/MAX policy), §15 (notification semantics), §10 (invariant tests), §9 tests tables expanded. RUBY_VERSION → SERVER_VERSION, PYTHON_VERSION → CLIENT_VERSION. |
| `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md` | Added Changelog-vs-design subsection. Task 2/3 compat code now uses strict regex + "Call get_version" hints + with_range defined?-guards. Tasks 4 and 5 fully restructured (was: Task 4=server-compat+broken test-double, Task 5=handlers/system; now: Task 4=handlers/system FIRST, Task 5=server-compat with REAL Dispatch.handle + REAL Core::Server). Task 6 adds conftest update step + dict assertion + -32001 remap + _RETRY_SAFE_TOOLS entry. Task 7 catches SketchUpError + two-way check. Task 9 release.md gets three invariant tests. Task 12 expected counts updated. RUBY_VERSION → SERVER_VERSION, PYTHON_VERSION → CLIENT_VERSION. |

## Статистика

- Всего замечаний: **31**
- Автоисправлено (без обсуждения): **24** (CRITICAL-1..7, CONCERN-1, 2, 5, 6, 7, 8, 9, 10, 11, 12, SUGGESTION-1..7, QUESTION-3)
- Авто-применено после анализа: **3** (QUESTION-1 two-way, QUESTION-2 str, QUESTION-4 keep)
- Обсуждено с пользователем: **1** (CONCERN-3 — user chose rename to SERVER_VERSION + extended to PYTHON_VERSION→CLIENT_VERSION)
- Отклонено: **2** (CONCERN-4 micro-perf, CONCERN-13 weak import test)
- Повторов (автоответ): **0** (first iteration)
- Пользователь сказал "стоп": **Нет**
- Агенты: codex-executor (gpt-5.5/xhigh), ccs-executor (glm-5.1), ollama-executor (kimi K2.6, minimax M2.7, deepseek V4 Pro)

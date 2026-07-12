## TASK

Execute the implementation plan for **SketchUp menu-driven settings UI** — replacing the Ruby ENV-based configuration with a `UI::HtmlDialog` opened from the Plugins menu, persisted via `Sketchup.write_default`.

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-05-11-menu-settings-ui-design.md`
- Plan:   `docs/superpowers/plans/2026-05-11-menu-settings-ui.md`

Read both documents first. The plan has 8 tasks (Task 1 → Task 8). Spec coverage table at the bottom of the plan maps each spec section to the task implementing it.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context.
2. Briefly summarize your understanding (3–5 sentences).
3. **WAIT for user instruction before taking any action.**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

This work emerged from a brainstorming session and went through one round of external code review (iteration 1, 4 reviewers). Critical context not contained in the design/plan itself:

### Design decisions made with the user (do NOT relitigate)

1. **Scope:** exactly 3 settings — host, port, log_level. Status info / read-only stats were explicitly rejected as out-of-scope.
2. **ENV is REMOVED from the Ruby side.** No fallback, no override — clean cut. Python side keeps ENV (it is launched from Claude Desktop config, where ENV is natural).
3. **Persistence:** `Sketchup.write_default` only. JSON file and in-memory storage were both rejected.
4. **UI:** `UI::HtmlDialog` — chosen explicitly by the user over `UI.inputbox` ("more convenient if we extend later"). Assumes SketchUp ≥ 2017.
5. **Apply on Save:** log-level applies immediately (Logger reads `Config.log_level` per call); host/port changes prompt the user via `UI.messagebox`. Auto-restart and apply-on-next-start were rejected.

### Critical lessons from review iter-1 (already encoded in design/plan)

- **`Config.update!` must mutate runtime BEFORE persistence.** All 4 reviewers flagged this. Order is: in-memory assignments → `write_default` calls. Any mid-write failure leaves the current session consistent and old prefs intact. **Do NOT swap this back.**
- **After successful Save, Ruby MUST call `on_load_state(dialog)`** to refresh the form and status banner. Otherwise the UI shows stale data.
- **`UI.messagebox` inside an `action_callback` freezes SketchUp on Windows.** All messagebox calls in the save flow are wrapped in `UI.start_timer(0, false) { … }`. **Do NOT unwrap them.**
- **Task 2 deliberately fuses what would otherwise be "consumers" + "boot wiring" + "running_config" + tests.** Splitting it back would leave the working tree in a state where Config consumers reference accessors but no boot wiring populates them — `TCPServer.new(nil, nil)` at runtime. **Keep Task 2 as one atomic commit.**
- **`test/test_application.rb` uses an injected `server_class` (StubServer)** to stay free of SketchUp dependencies, mirroring the Config DI pattern. The test file stubs `Sketchup`, `UI`, and `SKETCHUP_CONSOLE` at the top.
- **`SettingsValidator::HOST_CHARSET`** = `\A[A-Za-z0-9._\-:]+\z`. Allows unbracketed IPv6 (`::1`) because `TCPServer.new` takes addresses without brackets, but rejects spaces, slashes, etc.
- **Migration banner** (`Config.show_migration_banner!`) detects legacy ENV presence AND empty prefs AND not-already-notified, then shows a one-time `UI.messagebox` and sets the `migration_notified` flag. **It does NOT read ENV values into Config.** The architectural decision to drop ENV stands.
- **`js_safe_json` helper** escapes `</` → `<\/` before `execute_script`. Defense in depth for JSON-in-script context. Use it everywhere instead of raw `JSON.generate`.

### Reviewer dismissals (intentional, do not "fix")

- `STYLE_DIALOG` (not `STYLE_UTILITY`) — chosen for settings UX.
- `SO_REUSEADDR` for `TCPServer` — MRI sets it by default on Linux/macOS/Windows; no code change.
- `running_config` not cleared on `Server#reset_client` — pre-existing issue, out of scope.
- No logger tests added — out of scope.
- No export/import settings — YAGNI.

### Code review status

- iter-1 ran with 4 external reviewers (gemini, ccs-glm, ollama-kimi, ollama-deepseek). 30 issues surfaced, 22 auto-fixed in design + plan, 8 dismissed with rationale.
- `codex-executor` was blocked by auto-mode security policy — did not contribute.
- `ollama-minimax` hung mid-stream and never returned. Not blocking.
- iter-1 protocol: `docs/superpowers/specs/2026-05-11-menu-settings-ui-review-iter-1.md`.
- iter-1 commit: `a9e5d92`.

### Test runner caveat

Check `test/run_all.rb` before adding new test files. If it lists tests explicitly (not via `Dir["test_*.rb"]`), add `require_relative` lines for `test_settings_validation.rb` and `test_application.rb`.

### Branch state

- Branch: `feature/menu-settings-ui` (created from master)
- master is untouched
- Branch already contains the design doc, plan doc, merged review, iter-1 protocol — no implementation commits yet
- Untracked `docs/session-transfer-2026-05-07-132037.md` exists from a prior session — **ignore it**, do NOT add it to any commit

### What NOT to do during implementation

- Do **NOT** silently revert any iter-1 fix (especially `Config.update!` ordering, `on_load_state`-after-save, `UI.start_timer` wrap around messagebox, the merged Task 2).
- Do **NOT** split Task 2 back into smaller atomic units.
- Do **NOT** create new files under `docs/superpowers/` — those are removed before PR per the user's global rule.
- Do **NOT** push to remote without explicit user request.
- Do **NOT** modify Python code under `src/sketchup_mcp/` or its tests — Python ENV is intentionally untouched.
- Do **NOT** add features beyond what the plan specifies. The plan is the contract.

## PLAN QUALITY WARNING

The plan was written before some details of the surrounding code were verified. It may contain:
- Inaccurate file:line references after recent changes
- Code snippets that subtly diverge from the actual file content (line endings, whitespace)
- Assumptions about `test/run_all.rb` structure that need adapting
- Migration-banner detection logic that might need adjusting if SketchUp's `Sketchup.read_default` returns surprising default-marker semantics

**If you notice any issue during implementation:**
1. STOP before proceeding with the problematic step.
2. Clearly describe the problem.
3. Explain why the plan does not work or seems incorrect.
4. Ask the user how to proceed.

Do NOT silently work around plan issues or make significant deviations without user approval. Reviewers in iter-1 specifically called out plan inconsistencies as a recurring class of issue.

## After all 8 tasks complete

Use `/superpowers:finishing-a-development-branch` to wrap up the branch (clean up the docs/superpowers/ files before any PR, per the user's global rule).

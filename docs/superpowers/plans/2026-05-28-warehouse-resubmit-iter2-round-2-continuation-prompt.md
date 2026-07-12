# Continuation: Iter-2 Auto-Fixes Round 2 + Iter-2 Log + Final Commit

## TASK

Continue the iter-2 review processing for **warehouse-resubmit v0.2.0**.
Round 1 (13 of 25 auto-fixes) is already committed on this branch
(`feature/warehouse-resubmit`, commit `644d193`). You must apply the
remaining 12 auto-fixes, then generate the iter-2 log file, then make
the final decisions+log commit.

## CRITICAL: DO NOT START WORKING

After loading all context below:
1. Read the documents and understand the current state.
2. Report what you understood (brief summary, ≤5 lines).
3. **WAIT for explicit user instructions** before taking ANY action.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`

**Recent iter-2 commit:** `644d193 docs: review iter 2 — partial auto-fixes round 1 (warehouse-resubmit)`

Read that commit's body via `git show 644d193 -s` — it enumerates every
applied AUTO fix in round 1, every fix deferred to round 2, every
DISMISSED issue with the reason, and every REPEAT.

**Working tree:** should be clean of tracked-file modifications after
round 1 commit. Many pre-existing untracked files (session-transfer
docs, `.gemini/`, `diff.patch`, other superpowers plans/specs) — do NOT
stage them. Use explicit `git add <path>` per iter-1 CONCERN-7 commit
policy.

## DOCUMENTS

Read in this order:

1. **Iter-2 merged review (input):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md` — raw output from the 3 reviewers (codex / albb-deepseek / albb-kimi) + failure notes for glm and albb-qwen.

2. **Iter-1 decision log (autoanswers, for reference):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md` — already-decided issues that round 2 must not re-litigate.

3. **Design (current state, iter-1 + iter-2 round 1 patched):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` — round 1 already updated §4.3 (timer rescue), §5.1 (preserve log_tool), §5.3 (file_uri_for helper), §7 (peer_label "unknown" + 2 new silent-rescue rows). DO NOT re-apply those.

4. **Plan (current state, iter-1 + iter-2 round 1 patched):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` — round 1 already updated Files headers (Tasks 4/8/9/10/13), Step 2.11.b ("unknown" preservation), Step 12.8 (PATTERNS), Step 13.6 (commit message). DO NOT re-apply those.

5. **Iter-1 decisions:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md` — 32 issues, all resolved before iter-2 ran. Don't re-litigate any of these.

## ROUND-2 PUNCH LIST (12 auto-fixes remaining)

Apply each fix exactly as described. The reviewer source for each is in
the merged iter-2 file (search by issue ID). Most are mechanical text
edits. STOP and ask the user if an exact-string anchor doesn't match
(per iter-1 plan-quality warning).

### Plan preamble

1. **CONCERN-2 — macOS sed portability**: add a one-line note to plan
   preamble warning that `sed -i` calls in Tasks 1/12 use GNU syntax;
   on macOS BSD sed, substitute `gsed` (`brew install gnu-sed`) or
   adapt to `sed -i.bak '...' file && rm -f file.bak` form. Place
   inline near the existing «Commit policy» preamble.

### Plan Step 3.3 — Logger (CRITICAL-1, the biggest fix)

2. **Surgical rewrite of Logger module**: the current Step 3.3 replaces
   the entire module body, which (a) DROPS `Logger.log_tool` (used 9 times
   in `application.rb` + `server.rb`) and (b) emits FULL backtrace at
   every log level (current code gates backtrace to `DEBUG` and caps at
   `first(3)`). Both are regressions. Replace the «Edit … with the
   following» block with explicit per-method edits:
   - Add `LINE_PREFIX = "[MCPforSU]".freeze` constant.
   - Add private `self._emit(line)` helper containing the
     `defined?(SKETCHUP_CONSOLE)` branch (current `write` method's body).
   - Modify `self.log` body so the existing `line = "[#{Time.now...}] [#{level}] #{msg}"`
     becomes `"[#{Time.now.utc.iso8601}] #{LINE_PREFIX} [#{level}] #{msg}"`
     and the bare `write(line)` becomes `_emit(line)`.
   - Modify `self.log_error`: preserve the existing 3-arg signature
     `(tool, exception, client_label: nil)` and the existing body
     building `tool=#{tool} client=#{client_label} class=#{exception.class.name} msg=#{exception.message}`
     plus the DEBUG-only `first(3)` backtrace branch. Just route both
     `log("ERROR", body)` and the backtrace `write("    #{bt}")` lines
     through `_emit` so the prefix attaches. Backtrace continuation
     lines: `_emit("#{LINE_PREFIX}     #{bt}")`.
   - KEEP `self.log_tool(tool, status, extra = nil, client_label: nil)`
     verbatim — it's a public API used by `application.rb` (2 calls) and
     `server.rb` (7 calls).
   - Existing public `self.write` can become private `self._emit` —
     update its single internal caller. NB: no external callers per
     `grep -r 'Logger.write' src/sketchup_mcp su_mcp/`.
   - Update the new `test_log_error_backtrace_lines_carry_prefix` test
     (added in iter-1) so it sets `Config.log_level = "DEBUG"` before
     raising, otherwise `log_error` will not emit any backtrace lines
     (DEBUG gate). Otherwise the test silently passes vacuously.

### Plan Step 4.3 — Config (4 small fixes)

3. **CRITICAL-7 — delete Step 4.3 subsection (f)**: it instructs an
   ad-hoc `setup` block resetting host/port/log_level/eval_enabled/
   log_to_file/log_file_path manually, which contradicts the
   `ConfigReset.reset_all!` introduced in Step 4.0. Delete the (f)
   subsection entirely. Confirm Step 4.0's `ConfigReset.reset_all!`
   covers every field.

4. **CONCERN-3 — boolean coercion helper**: in Step 4.3(c)
   `load_from_defaults!`, the line
   `self.log_to_file = !!raw_l2f` (and the eval_enabled equivalent)
   would silently coerce a persisted string `"false"` to `true`.
   Replace `!!raw_l2f` and the eval_enabled `!!raw_eval` with a
   `coerce_bool_pref(value, default:)` helper that accepts only
   native `true`/`false` (matching what `Settings.write_default`
   writes) and falls back to the default for everything else
   (logging a one-shot WARN via `Logger.log("WARN", ...)`). Define
   the helper as a private module function in `config.rb`.

5. **SUGGESTION-2 — non-inherited `const_defined?`**: in Step 4.3(e)
   `eval_enabled?` getter, change `Core.const_defined?(:BuildProfile)` to
   `Core.const_defined?(:BuildProfile, false)` and
   `Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT)` to the
   same `(:EVAL_ENABLED_BY_DEFAULT, false)` form. Prevents inherited
   constant false-positives (e.g. via Object#const_defined?).

6. **SUGGESTION-3 — `truthy?` nil semantics comment**: in Step 7.3 (the
   validator), add a one-line comment to `self.truthy?` explaining that
   `nil` normalises to `false` because the dialog never sends nil — but
   semantically a missing pref means «unset», not «false». Document the
   distinction so a future reader sees that nil→false in the validator
   is a UI-layer convenience, not a Config-layer truth-value claim.

### Plan Step 4.5.a — load comment

7. **SUGGESTION-5 — `load` vs `require` comment**: in the test fixture
   added in Step 4.5.a, add a one-line comment after `load @tmp.path`:
   `# load (not require) because we re-define the same constant per setup; require would memoise the first definition.`

### Plan new Step 4.7.a — extension.json static test

8. **QUESTION-3 — static `extension.json` test**: add a new step
   numbered `4.7.a` (after Step 4.7 commit) that creates
   `test/test_extension_json.rb`:
   ```ruby
   require "minitest/autorun"
   require "json"

   class TestExtensionJson < Minitest::Test
     EXT_JSON = File.expand_path("../mcp_for_sketchup/extension.json", __dir__)

     def setup
       @meta = JSON.parse(File.read(EXT_JSON))
     end

     def test_product_id_matches_new_identity
       assert_equal "MCP_FOR_SKETCHUP", @meta["product_id"]
     end

     def test_name_matches_display
       assert_equal "MCP Server for SketchUp", @meta["name"]
     end
   end
   ```
   Reason: catch commit-time regression of either field before someone
   needs to run `package.rb`. The post-build verify (Step 10.2) only
   catches it at .rbz-build time, much later.

### Plan Step 5.1 — strengthen DEBUG fallback test

9. **CONCERN-10 — `test_log_to_file_failure_falls_back_silently` should
   assert the DEBUG fallback line**: extend the test from «doesn't
   raise» to also capture stdout and assert it contains
   `[MCPforSU] [DEBUG] log file write failed`. Design §5.2 promises
   this one-shot DEBUG line — the test should pin it.

### Plan Step 8.2 — Settings dialog (CRITICAL-2)

10. **CRITICAL-2 — timer rescue + persist_and_finalize helper**:
    - Extract the host/port runtime+restart logic from the normal-path
      branch into a private `self.persist_and_finalize(dialog,
      normalized, current_runtime, override_eval_enabled: nil)` helper.
    - The normal-path branch and the confirm-Yes branch both call this
      helper (Yes-branch passes `override_eval_enabled: true`). Without
      this, the Yes-branch skips the `need_restart` check and the
      `dialog.close` deferral.
    - Wrap the timer-block body in
      `begin … rescue StandardError => e; Logger.log_error("settings_dialog.eval_confirm", e); dialog.execute_script("window.applyState(#{js_safe_json(load_state_payload)}); window.onSaveResult(#{js_safe_json({ok:false, errors:{_general: "Internal error: #{e.message.scrub('?')}"}})})"); end`.
      Outer `on_save` rescue does NOT cover the timer block (it fires
      after the action_callback frame returns).

### Plan Step 8.3 — file_uri_for (CRITICAL-3)

11. **CRITICAL-3 — replace `URI::File.build` with `file_uri_for` helper**:
    update Step 8.3 to:
    - Add `require "uri"` at top of `application.rb` (already in the
      step).
    - Define a private `self.file_uri_for(path)` helper:
      ```ruby
      def self.file_uri_for(path)
        encoded = File.expand_path(path).gsub('\\', '/')
        encoded = "/#{encoded}" if encoded =~ /\A[A-Za-z]:/   # Windows drive letter
        encoded = URI::DEFAULT_PARSER.escape(encoded)
        "file://#{encoded}"
      end
      ```
    - Use it from `show_log`: `::UI.openURL(file_uri_for(MCPforSketchUp::Core::Config.log_file_path))`.
    - Add a new test in `test/test_application_show_log.rb` (or extend
      an existing test_application file) covering: (a) path with spaces
      → encoded `%20`; (b) Windows-style path `"C:\\Users\\foo bar"` →
      `file:///C:/Users/foo%20bar`; (c) non-ASCII path → encoded.

### Plan Step 10.2 — package.rb (CRITICAL-4 + CRITICAL-8)

12. **CRITICAL-4 — move `File.write` inside `begin`**: in Step 10.2 the
    `File.write(build_profile_path, …)` call currently sits BEFORE the
    `begin` block, so a failure in `File.write` itself (disk full, perms)
    would leak the partial file. Reorder so:
    ```ruby
    build_profile_path = File.join(EXTENSION_NAME, 'core', 'build_profile.rb')
    temp_dir = "#{EXTENSION_NAME}_temp"
    begin
      File.write(build_profile_path, <<~RUBY)
        ...
      RUBY
      puts "Generated #{build_profile_path}: ..."
      FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
      ...
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
      FileUtils.rm_f(build_profile_path)
    end
    ```

13. **CRITICAL-8 — also verify `name` field**: in Step 10.2 step 5
    (post-build verification), the `Zip::File.open` block currently
    checks `product_id` and `version` but NOT `name`. Reviewer's
    rejection-of-record for v0.1.0 was the NAME, so silently regressing
    it later would re-trigger the same rejection. Add:
    ```ruby
    unless meta["name"] == "MCP Server for SketchUp"
      raise "post-build: name mismatch — got #{meta['name'].inspect}, expected \"MCP Server for SketchUp\""
    end
    ```

### Plan Step 10.6.a — build_profile content assertion (SUGGESTION-1)

14. **SUGGESTION-1 — verify `build_profile.rb` content inside the built
    .rbz**: extend `test_package_default_variant.rb` to open the produced
    `mcp_for_sketchup_v*-warehouse.rbz`, read
    `mcp_for_sketchup/core/build_profile.rb`, and assert it contains
    `EVAL_ENABLED_BY_DEFAULT = false` (the warehouse default). Use
    `Zip::File.open` like the post-build verify in Step 10.2.

### Plan Step 12.6 — release.md (CRITICAL-5)

15. **CRITICAL-5 — remove `SU_MCP_SERVER` literal**: in Step 12.6 the
    Markdown block contains two occurrences of `SU_MCP_SERVER` in
    user-facing release-docs text. Step 12.8's `git grep -inE
    'SU_MCP|SU_MCP_SERVER'` would fail on these. Replace both with a
    descriptive phrase (e.g. «the dead v0.1.0 listing under the prior
    `su_`-prefixed product id», without writing the literal). Verify
    Step 12.8 still passes after the change.

### Plan Step 13.3 — eval_skipped scope (CONCERN-12)

16. **CONCERN-12 — `eval_skipped` mutable container**: the current
    Step 13.3 says `eval_skipped = 0` «at the top of the run» plus
    `eval_skipped += 1` inside coroutines. Python `nonlocal` semantics
    will bite if the increment is in a nested function. Replace with a
    mutable container pattern: `eval_skipped = [0]` at top; `if result
    is None: eval_skipped[0] += 1` at call site; `print(f"… {eval_skipped[0]} skipped …")`
    at end. Note in plan: «mutable list used because asyncio coroutines
    inherit lexical scope but assignment to nonlocal int requires
    explicit `nonlocal`».

### Plan Step 13.4.a — smoke_check.py sys.path guard (CONCERN-5)

17. **CONCERN-5 — guard `sys.path.insert` in `smoke_check.py`**: the
    test in Step 13.4.a uses `importlib.util.spec_from_file_location`
    to load `smoke_check.py`, which executes the module body —
    including `sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))`
    at the file's line 36. This pollutes `sys.path` for all subsequent
    pytest tests. Either:
    - **Variant A**: add an `if __name__ == "__main__":` guard around the
      `sys.path.insert` in `smoke_check.py`. The Path import + helper
      definitions remain at module scope. Cleaner long-term.
    - **Variant B**: in `tests/test_smoke_helpers.py`, snapshot `sys.path`
      before `_spec.loader.exec_module(_smoke)` and restore in `try/finally`.
      Contained but adds noise.
    Pick A (one-line guard in smoke_check). Add a brief comment in the
    plan step describing why.

### Plan Step 14.7 — macOS modality (QUESTION-2)

18. **QUESTION-2 — macOS UI.messagebox modality acceptance**: add a
    subitem `11.` under Step 14.7 manual acceptance: on macOS,
    repeat steps 7a-9 and verify the eval-enable confirmation
    `UI.messagebox` appears in front of the SketchUp window (not behind
    it) and is fully modal until dismissed. Two-phase deferred flow
    should make this OK on macOS too, but verify empirically.

### Plan Step 14.7.7a — write_default(nil) comment (SUGGESTION-4)

19. **SUGGESTION-4 — comment about `write_default(nil)` semantics**:
    in Step 14.7.7a (clear pref to force BuildProfile default), append
    a one-line comment immediately above the `Sketchup.write_default`
    call: «`write_default(..., nil)` is the SketchUp API for *deleting*
    the key from the prefs section — not «set to nil». The next
    `read_default(SECTION, key, default)` will then return `default`,
    which is what triggers the BuildProfile fallback in `eval_enabled?`.»

---

After applying all 19 fixes above, run:

```bash
git status --short
```

Confirm only `design.md` and `plan.md` are modified (plus any new test
files you wrote into the working tree). Commit with explicit paths only.

## ITER-2 LOG FILE (Step 13 of skill)

After all fixes are in, write
`docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`
following the same structure as the iter-1 log:

- Header with sources (design, plan, reviewer set, merged output path)
- One section per issue (ID, title, quote, Источник, Статус, Ответ, Действие)
- Statuses to use:
  - Автоисправлено (round 1 — applied in commit `644d193`)
  - Автоисправлено (round 2 — applied in this session)
  - Отклонено (false positive)
  - Повтор (autoanswered with reference)
- Table of «Изменения в документах» (file → change)
- Stats block: total / auto-round-1 / auto-round-2 / discussed / dismissed / repeat

The 32 issues — round-1 commit `644d193` body has them all enumerated
with disposition.

## FINAL COMMIT (Step 14 of skill)

```bash
git add docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
        docs/superpowers/plans/2026-05-28-warehouse-resubmit.md \
        docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md
git commit -m "docs: review iter 2 — round 2 fixes + decisions log (warehouse-resubmit)"
```

(merged-iter-2.md was committed in round-1; do not re-add.)

## STEP 15 OF SKILL

After the final commit, ask the user via AskUserQuestion whether to:
- Start a fresh iter-3 review (likely diminishing returns — iter-2 only
  surfaced 25 net AUTO fixes, none CRITICAL beyond known invariants)
- Stop and begin execution of the implementation plan
- Other

## INSTRUCTIONS

1. Read the documents listed above.
2. Summarize current state in ≤5 lines.
3. **STOP and WAIT** — do NOT start applying fixes.
4. Ask user: «Применить 19 round-2 fixes последовательно с финальным commit, или сначала пройтись по конкретным проблемным fix'ам?»

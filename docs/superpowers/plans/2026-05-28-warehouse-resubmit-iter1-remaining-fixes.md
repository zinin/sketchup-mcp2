# Iter-1 — Remaining Auto-Fixes for Plan

**Purpose:** Hand-off document for a fresh session to continue applying iter-1 auto-fixes to `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`. The design (`2026-05-28-warehouse-resubmit-design.md`) has already been updated; remaining mechanical fixes target the plan only.

**Status of fixes from iter-1 classification (30 AUTO total):**

| # | Status | File | Note |
|---|---|---|---|
| CRITICAL-1 | ✅ design / ⏳ plan | both | Design §4.2 + §5.2 done. Plan Task 4 still uses `false` as DEFAULTS — needs sentinel-`nil`. |
| CRITICAL-2 | ⏳ plan | plan | `on_load_state` needs `Config.eval_enabled?` not `Config.eval_enabled`. |
| CRITICAL-3 | ✅ design / ⏳ plan | both | Design §4.3 done. Plan Task 8 Step 8.1 (HTML) + 8.2 (Ruby) need two-phase flow. |
| CRITICAL-4 | ⏳ plan | plan | Smoke wrapper catches `SketchUpError(code=-32010)`, not text. |
| CRITICAL-5 | ⏳ plan | plan | Lowercase `su_mcp` rename + `test/run_all.rb` + `CLAUDE.md` manual + verification grep. |
| CRITICAL-6 | ⏳ plan | plan | `package.rb` `begin/ensure` cleanup. |
| CRITICAL-7 | ✅ done | plan | Preamble rewritten. |
| CRITICAL-8 | ⏳ plan | plan | Lowercase `saved_eval` var + add `require_relative ".../helpers/validation"`. |
| CONCERN-1 | ✅ design / ⏳ plan | both | Plan Step 3.3 needs prefix in shared `write` method. |
| CONCERN-2 | ✅ design / ⏳ plan | both | Plan Task 2 needs 2 more rescues (`Geometry.safe_abort`, `ClientState#peer_label`). |
| CONCERN-3 | ⏳ plan | plan | Task 12 Step 12.6: rewrite EW section in release.md. |
| CONCERN-4 | ⏳ plan | plan | Task 8: `height: 480`, `scrollable: true`. |
| CONCERN-5 | ✅ design / ⏳ plan | both | Plan Task 7 validator + Task 8 show_log: parent dir + URI escape. |
| CONCERN-7 | ⏳ plan | plan | Replace `git add -A` with explicit paths in all 14 task commits. |
| CONCERN-8 | ⏳ plan | plan | Word-boundary `\bSU_MCP\b` + grep verification before sed in Step 1.4. |
| CONCERN-9 | ⏳ plan | plan | Unified test helper `ConfigReset.reset_all!`. |
| CONCERN-10 | ⏳ plan | plan | Back-compat test for `update!` with 3 keyword args. |
| SUGGESTION-1 | ⏳ plan | plan | `EVAL_DISABLED_CODE = -32010` in `compat.py`. |
| SUGGESTION-2 | ⏳ plan | plan | Fixture-based test for github BuildProfile path. |
| SUGGESTION-3 | ⏳ plan | plan | `package.rb` post-build assertion on `extension.json`. |
| SUGGESTION-4 | ⏳ plan | plan | Tracked-grep script in Task 12 (all old markers). |
| SUGGESTION-5 | ⏳ plan | plan | Five real-contract tests (BuildProfile, raw smoke skip, logger backtrace, default variant, explicit pref override). |
| SUGGESTION-6 | ⏳ plan | plan | `refute_empty` in `test_operation_names.rb`. |
| SUGGESTION-7 | ⏳ plan | plan | Manual Edit-ops for `CLAUDE.md` (replaces sed in Step 12.4). |
| QUESTION-1 | ⏳ plan | plan | EW release.md section (overlap with CONCERN-3). |
| QUESTION-3 | ⏳ plan | plan | Add «clear eval_enabled pref» to Step 14.7 acceptance. |
| QUESTION-4 | ⏳ plan | plan | Add Trimble intake pre-check step. |
| QUESTION-5 | ⏳ plan | plan | Verify `uv.lock` git status, adjust Step 11.9. |
| QUESTION-6 | ⏳ plan | plan | Note description capitalization as intentional in Step 1.9. |
| QUESTION-7 | ⏳ plan | plan | Bake `read_default` verification into CRITICAL-1 test (already documented in design §4.2). |

---

## Detailed patches (apply in plan)

### CRITICAL-1 — Sentinel-`nil` in plan Task 4

**Step 4.1** — replace the test `test_defaults_include_eval_enabled_false` body:

```ruby
def test_defaults_include_eval_enabled_nil
  # Sentinel — unset pref triggers BuildProfile fallback (see spec §4.2).
  assert_nil C::DEFAULTS[:eval_enabled]
end
```

Rename the method too. Also add:

```ruby
def test_eval_enabled_question_mark_when_no_pref_and_no_build_profile_returns_false
  C.load_from_defaults!(StubReader.new)
  refute MCPforSketchUp::Core.const_defined?(:BuildProfile),
    "test env should not have build_profile.rb loaded"
  refute C.eval_enabled?
end

def test_eval_enabled_question_mark_when_pref_explicit_false_returns_false
  C.load_from_defaults!(StubReader.new("eval_enabled" => false))
  refute C.eval_enabled?
end

def test_read_default_passes_nil_default_for_eval_enabled_sentinel
  # Sketchup.read_default with explicit nil default returns nil when key absent,
  # actual value (including false) when present. Verifies sentinel mechanism.
  reader = StubReader.new  # no eval_enabled key
  C.load_from_defaults!(reader)
  assert_nil C.eval_enabled
end
```

**Step 4.3(a)** — DEFAULTS hash:
```ruby
DEFAULTS = {
  host:           "127.0.0.1",
  port:           9876,
  log_level:      "WARN",
  eval_enabled:   nil,  # sentinel; unset → falls back to BuildProfile::EVAL_ENABLED_BY_DEFAULT
  log_to_file:    false,
  log_file_path:  File.join(Dir.tmpdir, "mcp_for_sketchup.log").freeze,
}.freeze
```

**Step 4.3(c)** — `load_from_defaults!`:
```ruby
raw_eval = reader.read_default(SECTION, "eval_enabled", nil)
self.eval_enabled  = raw_eval.nil? ? nil : !!raw_eval
```

(rest of load_from_defaults stays as currently written, but using `nil` for `eval_enabled` default arg to `read_default`)

**StubReader** in test helper must support `nil` default behavior:
```ruby
def read_default(section, key, default = nil)
  @prefs.key?(key) ? @prefs[key] : default
end
```

### CRITICAL-2 — Plan Task 8 Step 8.2 `on_load_state`

Replace:
```ruby
eval_enabled:   MCPforSketchUp::Core::Config.eval_enabled,
```
with:
```ruby
eval_enabled:   MCPforSketchUp::Core::Config.eval_enabled?,
```

### CRITICAL-3 — Plan Task 8 Step 8.1 (HTML) + Step 8.2 (Ruby)

**Step 8.1 HTML** — after `eval_enabled` checkbox row, ADD:
```html
<div class="error" id="eval_enabled-error"></div>
```

In `clearErrors` JS function, change the array to:
```js
['host', 'port', 'log_level', 'log_file_path', 'eval_enabled'].forEach(...)
```

**Step 8.2 Ruby** — replace `on_save` eval-confirmation block with the two-phase flow per design §4.3:

```ruby
if normalized[:eval_enabled] && !previous_eval_enabled
  # Defer the messagebox out of the action_callback frame (Windows quirk).
  ::UI.start_timer(0, false) do
    if confirm_eval_enable
      # User confirmed; persist now.
      MCPforSketchUp::Core::Config.update!(
        host: normalized[:host], port: normalized[:port],
        log_level: normalized[:log_level],
        eval_enabled: true,
        log_to_file: normalized[:log_to_file],
        log_file_path: normalized[:log_file_path],
      )
      dialog.execute_script(
        "window.onSaveResult(#{js_safe_json({ok: true})}); " \
        "window.applyState(#{js_safe_json(load_state_payload)})"
      )
    else
      # User declined; revert UI to the previously-saved state.
      dialog.execute_script(
        "window.applyState(#{js_safe_json(load_state_payload)}); " \
        "window.onSaveResult(#{js_safe_json({ok: false, errors: {eval_enabled: 'Cancelled — Ruby evaluation remains disabled'}})})"
      )
    end
  end
  return
end
```

Extract a `load_state_payload` helper from `on_load_state` so both methods share the state-building logic.

### CRITICAL-4 — Plan Task 13 Step 13.2-13.3 smoke skip

Replace `_maybe_skip_eval` helper with:
```python
async def _maybe_skip_eval(label, coro):
    """Run an eval_ruby-dependent step; if Ruby returns -32010, skip and tally.

    smoke_check uses raw SketchUpConnection.send_command, which raises
    SketchUpError on JSON-RPC error envelopes — we must catch that, not
    inspect the textual response.
    """
    try:
        return await coro
    except SketchUpError as e:
        if e.code == -32010:
            print(f"  ⚠ {label}: skipped (eval_ruby disabled in extension settings)")
            return None
        raise
```

Imports: ensure `from sketchup_mcp.errors import SketchUpError` is present.

### CRITICAL-5 — Lowercase rename completion

**Step 1.4** — extend after the existing sed:
```bash
# Lowercase su_mcp in Ruby file headers, Python compat messages, etc.
# Use word-boundary to avoid mangling unrelated identifiers.
find mcp_for_sketchup/mcp_for_sketchup -type f -name '*.rb' \
  -exec sed -i 's|\bsu_mcp_v|mcp_for_sketchup_v|g' {} +
sed -i 's|\bsu_mcp_v|mcp_for_sketchup_v|g' \
  src/sketchup_mcp/compat.py mcp_for_sketchup/mcp_for_sketchup/core/compat.rb
```

**Step 1.6** — extend sed to include `run_all.rb`:
```bash
find test -type f \( -name 'test_*.rb' -o -name 'run_all.rb' -o -name '*_helper.rb' \) \
  -exec sed -i 's|\.\./su_mcp/su_mcp/|../mcp_for_sketchup/mcp_for_sketchup/|g; s/\bSU_MCP\b/MCPforSketchUp/g' {} +
```

**Step 12.4** — REPLACE the sed pass with manual Edit operations (see SUGGESTION-7 below). The current sed produces "mcp_for_sketchup/ — to be renamed mcp_for_sketchup/" which is nonsense.

**Step 12.8** — strengthen the grep:
```bash
# Strict tracked-grep: both case-variants of marker + display-name strings
git grep -inE 'su_mcp|SU_MCP|Sketchup MCP Server|SketchupMCP|SU_MCP_SERVER' \
  -- ':!docs/superpowers/specs/*' ':!docs/superpowers/plans/*' ':!docs/session-transfer-*' ':!CHANGELOG*' ':!*.lock'
test $? -eq 1 || { echo "FAIL: legacy markers still present"; exit 1; }
```

### CRITICAL-6 — Plan Task 10 Step 10.2 begin/ensure

Wrap the package.rb body in:
```ruby
build_profile_path = File.join(EXTENSION_NAME, 'core', 'build_profile.rb')
temp_dir = "#{EXTENSION_NAME}_temp"
begin
  # ... existing body: write build_profile, copy to temp_dir, zip ...
ensure
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  FileUtils.rm_f(build_profile_path)
end
```

### CRITICAL-8 — Plan Task 6 Step 6.1 test syntax + require

In test code, rename `SU_MCP_save_eval` → `saved_eval` (or `previous_eval`). Constants in Ruby start with uppercase letter; `SU_MCP_save_eval` triggers `dynamic constant assignment` error inside methods.

Also add to the requires block at top of `test/test_dispatch_post_handshake.rb`:
```ruby
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/eval"
```

### CONCERN-1 — Plan Step 3.3 prefix in shared write

Replace the `Logger.log` body with a private `_emit` that builds the prefixed line, called from both `log()` and `log_error()` (the latter for each backtrace line). Concretely:
```ruby
def self.log(level, msg)
  return if Config.level_value_for(level) < Config.level_value
  _emit("[#{Time.now.utc.iso8601}] #{LINE_PREFIX} [#{level}] #{msg}")
end

def self.log_error(tag, error)
  _emit("[#{Time.now.utc.iso8601}] #{LINE_PREFIX} [ERROR] #{tag}: #{error.class}: #{error.message}")
  (error.backtrace || []).each { |bt| _emit("#{LINE_PREFIX}     #{bt}") }
end

def self._emit(line)
  if defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
    SKETCHUP_CONSOLE.write(line + "\n")
  else
    $stdout.puts(line)
  end
  append_to_file(line) if Config.log_to_file
end
```

Update existing `test_logger.rb` test `test_log_error_writes_backtrace` to assert the prefix appears on backtrace lines too.

### CONCERN-2 — Plan Task 2 add 2 more silent rescues

Add steps after Step 2.11:

**Step 2.11.a**:
```ruby
# handlers/geometry.rb:13 (Geometry.safe_abort)
begin
  model.abort_operation
rescue StandardError => e
  MCPforSketchUp::Core::Logger.log("DEBUG",
    "Geometry.safe_abort: model.abort_operation raised: #{e.class}: #{e.message}")
end
```

**Step 2.11.b**:
```ruby
# core/client_state.rb:53 (#peer_label)
begin
  # ... existing peer probe logic ...
rescue StandardError => e
  MCPforSketchUp::Core::Logger.log("DEBUG",
    "ClientState#peer_label: peer probe raised: #{e.class}: #{e.message}")
  "<unknown>"
end
```

### CONCERN-3 — Plan Step 12.6 release.md rewrite

In release.md, find the section that says "EW rejects pre-encrypted .rbz, requires plain source" and replace with:
```markdown
### Submitting via Extension Warehouse (v0.2.0+)

Both `.rbz` variants are signed via the Trimble extension-signing service:

1. Build the warehouse variant: `(cd mcp_for_sketchup && ruby package.rb --variant=warehouse)`
2. Sign via Trimble: <https://extensions.sketchup.com/developer/sign-extension>
3. Submit the signed file through the Extension Warehouse intake form.
4. `product_id` is now `MCP_FOR_SKETCHUP` (replaces the v0.1.0 `SU_MCP_SERVER`).

For the GitHub-Release variant, run the same flow with `--variant=github` and upload alongside the Python wheel/sdist.
```

### CONCERN-4 — Plan Task 8 dialog size

In Step 8.2, find the `MCPforSketchUp::UI::HtmlDialog.new(...)` constructor call and change:
```ruby
HEIGHT: 360 → HEIGHT: 480,
scrollable: false → scrollable: true,
```

### CONCERN-5 — Plan Task 7 validator + Task 8 show_log

**Task 7 Step 7.3** — strengthen `log_file_path` check:
```ruby
if log_to_file
  if log_path.empty?
    errors[:log_file_path] = "Log file path must not be empty when 'Log to file' is enabled"
  else
    parent = File.dirname(File.expand_path(log_path))
    unless Dir.exist?(parent)
      errors[:log_file_path] = "Log file parent directory does not exist: #{parent}"
    end
  end
end
```

**Task 8 Step 8.3** — use URI::File for show_log:
```ruby
require "uri"

def self.show_log
  if MCPforSketchUp::Core::Config.log_to_file &&
     File.exist?(MCPforSketchUp::Core::Config.log_file_path)
    expanded = File.expand_path(MCPforSketchUp::Core::Config.log_file_path)
    ::UI.openURL(URI::File.build(path: expanded).to_s)
  elsif defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
    SKETCHUP_CONSOLE.show
  end
end
```

### CONCERN-7 — Replace `git add -A` everywhere

In each of the 14 task commit steps in the plan, replace `git add -A` with explicit file lists. Examples:
- Task 1: `git add mcp_for_sketchup/ test/ .gitignore` (after rename)
- Task 2: `git add mcp_for_sketchup/mcp_for_sketchup/handlers/{geometry,operations,joints,materials,model}.rb mcp_for_sketchup/mcp_for_sketchup/core/{application,server}.rb test/test_operation_names.rb`
- (do similar for tasks 3..14 — each task's "Files" list at the top tells you what to add)

Add to plan preamble: «Worktree must be clean of pre-existing untracked files before each commit step. Run `git status` before staging.»

### CONCERN-8 — Word-boundary sed

In Step 1.4 prefix the sed pass with a verification grep:
```bash
# Verify no SU_MCP occurrences inside string literals
git grep -n 'SU_MCP' -- mcp_for_sketchup/ | grep -vE '(module SU_MCP|SU_MCP::|"SU_MCP")' || echo OK
```

Then use word-boundary sed:
```bash
find mcp_for_sketchup/mcp_for_sketchup -type f -name '*.rb' \
  -exec sed -i 's/\bSU_MCP\b/MCPforSketchUp/g' {} +
```

### CONCERN-9 — Unified test helper

Add to Task 4 a new step before the test edits:
```ruby
# test/support/config_reset.rb (NEW FILE)
module ConfigReset
  def self.reset_all!
    c = MCPforSketchUp::Core::Config
    c.host = c.port = c.log_level = nil
    c.eval_enabled = c.log_to_file = c.log_file_path = nil
  end
end
```

Update `test_config.rb`, `test_logger.rb`, `test_application.rb` setup to call `ConfigReset.reset_all!`.

### CONCERN-10 — Back-compat smoke test

In Task 4 add:
```ruby
def test_update_with_only_3_args_does_not_touch_new_fields
  ConfigReset.reset_all!
  writer = StubWriter.new
  C.update!(host: "1.1.1.1", port: 1111, log_level: "INFO", writer: writer)
  assert_nil C.eval_enabled
  assert_nil C.log_to_file
  assert_nil C.log_file_path
  keys = writer.writes.map { |_, k, _| k }
  refute_includes keys, "eval_enabled"
  refute_includes keys, "log_to_file"
  refute_includes keys, "log_file_path"
end
```

### SUGGESTION-1 — `EVAL_DISABLED_CODE` in compat.py

In `src/sketchup_mcp/compat.py` add:
```python
EVAL_DISABLED_CODE = -32010
```

In `src/sketchup_mcp/tools.py` replace:
```python
_EVAL_DISABLED_CODE = -32010
```
with:
```python
from sketchup_mcp.compat import EVAL_DISABLED_CODE
```

And use `EVAL_DISABLED_CODE` instead of `_EVAL_DISABLED_CODE`.

### SUGGESTION-2 — Github BuildProfile fixture test

Add new `test/test_build_profile_fixture.rb`:
```ruby
require "minitest/autorun"
require "tempfile"

class TestBuildProfileFixture < Minitest::Test
  def setup
    @tmp = Tempfile.new(["build_profile", ".rb"])
    @tmp.write(<<~RUBY)
      module MCPforSketchUp
        module Core
          module BuildProfile
            VARIANT = "github".freeze
            EVAL_ENABLED_BY_DEFAULT = true
          end
        end
      end
    RUBY
    @tmp.close
    load @tmp.path
  end

  def teardown
    if MCPforSketchUp::Core.const_defined?(:BuildProfile)
      MCPforSketchUp::Core.send(:remove_const, :BuildProfile)
    end
    @tmp.unlink
  end

  def test_eval_enabled_question_mark_returns_true_when_pref_unset_and_buildprofile_true
    MCPforSketchUp::Core::Config.eval_enabled = nil
    assert MCPforSketchUp::Core::Config.eval_enabled?
  end

  def test_pref_overrides_buildprofile
    MCPforSketchUp::Core::Config.eval_enabled = false
    refute MCPforSketchUp::Core::Config.eval_enabled?
  end
end
```

### SUGGESTION-3 — Post-build assertion

In `package.rb` after the zip step, add:
```ruby
Zip::File.open(OUTPUT_NAME) do |zf|
  entry = zf.find_entry(File.join(EXTENSION_NAME, "extension.json"))
  raise "extension.json missing from .rbz" unless entry
  meta = JSON.parse(entry.get_input_stream.read)
  raise "product_id mismatch: #{meta['product_id']}" unless meta["product_id"] == "MCP_FOR_SKETCHUP"
  raise "version mismatch: #{meta['version']}" unless meta["version"] == VERSION
end
puts "extension.json verified: product_id=#{meta['product_id']}, version=#{meta['version']}"
```

(needs `require 'json'` at top of package.rb)

### SUGGESTION-4 — Tracked grep script

Replace Step 12.8 with:
```bash
# Strict tracked-grep over all old markers
PATTERNS='su_mcp|SU_MCP|Sketchup MCP Server|SketchupMCP|SU_MCP_SERVER'
git grep -inE "$PATTERNS" \
  -- ':!docs/superpowers/specs/*' \
     ':!docs/superpowers/plans/*' \
     ':!docs/session-transfer-*' \
     ':!CHANGELOG*' \
     ':!*.lock' && {
  echo "FAIL: legacy markers still present in tracked files"
  exit 1
}
echo "OK: no legacy markers"
```

### SUGGESTION-5 — Five real-contract tests

Add explicit steps in plan:
1. `test_build_profile_true_when_unset_pref_and_buildprofile_true` — see SUGGESTION-2
2. `test_explicit_pref_false_overrides_buildprofile_true` — see SUGGESTION-2
3. `test_package_rb_default_variant_is_warehouse` — shell-out from minitest, `system("ruby package.rb")` (no `--variant`) and assert filename contains `-warehouse`
4. `test_smoke_check_skips_on_minus_32010_error` — Python test in tests/test_smoke_helpers.py: monkeypatch `send_command` to raise SketchUpError(-32010); assert helper returns None and prints skip notice
5. `test_logger_backtrace_lines_include_prefix` — see CONCERN-1

### SUGGESTION-6 — `refute_empty` in test_operation_names.rb

In Step 2.1 add to the test class:
```ruby
def test_handlers_dir_is_not_empty
  files = Dir[File.join(HANDLERS, "*.rb")]
  refute_empty files, "handlers dir scan returned 0 files — check HANDLERS path"
end
```

### SUGGESTION-7 — Manual Edit for CLAUDE.md (replaces sed in Step 12.4)

REPLACE Step 12.4 with a series of explicit Edit operations. The CLAUDE.md file should be edited to:
1. Replace literal `su_mcp/su_mcp` → `mcp_for_sketchup/mcp_for_sketchup`
2. Replace `su_mcp/` → `mcp_for_sketchup/` ONLY where it refers to actual paths, NOT inside «to be renamed» annotations
3. Replace `` `SU_MCP` `` → `` `MCPforSketchUp` ``
4. Replace `SU_MCP::` → `MCPforSketchUp::`
5. Replace `Sketchup MCP Server` → `MCP Server for SketchUp`
6. Verify no «mcp_for_sketchup/ — to be renamed mcp_for_sketchup/» nonsense remains; if any «to be renamed» annotations existed they must be cleaned.

### QUESTION-1 — release.md EW section (already covered by CONCERN-3)

### QUESTION-3 — Step 14.7 clear pref

Add before step 14.7.8 (the eval_ruby acceptance test):
```
14.7.7a. Open Ruby Console: `Sketchup.write_default("MCPforSketchUp", "eval_enabled", nil)` to force the BuildProfile default. Then close and reopen Settings to verify the checkbox reflects the variant's build-time default (off for warehouse, on for github).
```

### QUESTION-4 — Trimble intake pre-check

Add Step 14.0 at the top of Task 14:
```
**Step 14.0: Trimble intake-form pre-check**

Open <https://extensions.sketchup.com/developer/submit> and confirm:
1. The form accepts a brand-new `product_id` (`MCP_FOR_SKETCHUP`) without requiring a link to the previous `SU_MCP_SERVER` submission.
2. The form accepts signed `.rbz` files (the Trimble signing service flow).

If either is gated by an approval queue, surface to the user BEFORE building artifacts so the submission can be sequenced correctly.
```

### QUESTION-5 — uv.lock status

Modify Step 11.9:
```bash
# Check whether uv.lock is tracked in git (it usually is for libraries)
if git ls-files --error-unmatch uv.lock 2>/dev/null; then
  uv lock 2>&1 | tail -5
  git add uv.lock
else
  echo "uv.lock not tracked; skipping lockfile regenerate"
fi
```

### QUESTION-6 — description capitalization note

Add to Step 1.9 after the JSON block:

> Note: `"description"` changes the casing of `Sketchup` → `SketchUp` (capital U). This is a deliberate consistency fix with the new display name, NOT part of the reviewer's name-rejection note. Mentioned here so it doesn't surprise a future reader.

### QUESTION-7 — read_default verification baked into CRITICAL-1 test

(See CRITICAL-1 test additions above — `test_read_default_passes_nil_default_for_eval_enabled_sentinel` verifies the read_default behavior assumption.)

---

## Disputed items (NOT auto-applied — for Step 12 discussion)

- **CONCERN-6** — test approach: regex-parse (current plan) vs design-promised mock recorder
- **QUESTION-2** — should `src/sketchup_mcp/prompts.py` mention the eval-gate?

These will be presented to the user one at a time per skill Step 12.

---

## How to resume in fresh session

1. Open `/continue-plan-fresh-session` skill.
2. Reference this file as the working spec.
3. Apply each `⏳ plan` row above in order.
4. After all auto-fixes applied → commit with message `docs: review iter 1 — auto-fixes (warehouse-resubmit)`.
5. Then process DISPUTED (2 items) one at a time per Step 12.
6. Then generate iter-1 file per Step 13 and commit per Step 14.

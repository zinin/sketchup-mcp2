# Merged Design Review — Iteration 1 (2026-05-28)

**Source documents:**
- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`

**Review agents (5 dispatched, 2.5 completed):**
- `codex-executor` (gpt-5.5, xhigh) — **completed** ✓
- `ccs-executor / glm` — **partial** (model produced full structured findings inside reasoning trace, but the run was killed by upstream before `output.txt` was flushed; summary section extracted from `raw.jsonl` thinking blocks)
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro 1M) — **completed** ✓
- `ccs-executor / albb-kimi` — **failed** (silent stall after 43 tool calls; no `result` event, no assistant text ever emitted; upstream likely timed out during generation phase)
- `ccs-executor / albb-qwen` — **failed** (Alibaba endpoint returned `Model not exist.` 400 — profile model id `qwen3.7-max[1m]` not valid on the MaaS endpoint; pre-fetch tool calls executed but no completion)

---

## codex-executor (gpt-5.5, xhigh)

Прочитал оба документа полностью, сверил с `CLAUDE.md` и ключевыми исходниками.

### Critical Issues

CRITICAL-1. `BuildProfile` не будет управлять default для GitHub-варианта.  
В плане `load_from_defaults!` читает `eval_enabled` с default `false`, затем всегда присваивает `self.eval_enabled = !!raw_eval`; поэтому `Config.eval_enabled?` уже никогда не дойдет до `Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT`. Это ломает главное различие `warehouse`/`github`: GitHub `.rbz` тоже стартует с eval off. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:653), [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:677), [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:724). Плюс Settings UI грузит `Config.eval_enabled`, а не effective `eval_enabled?` ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1517)).

CRITICAL-2. В Task 8 rollback при отказе от включения eval заявлен, но фактически не реализован.  
При `No` код только возвращает `onSaveResult(ok:false)` и не вызывает `applyState`, не снимает checkbox, не возвращает сохраненное состояние; в HTML нет `eval_enabled-error`, так что ошибка даже не отображается. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1540). Отдельно: комментарий обещает `UI.start_timer`, но `confirm_eval_enable` вызывает `UI.messagebox` прямо внутри callback, вопреки уже зафиксированной Windows-проблеме в текущем коде ([settings_dialog.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/ui/settings_dialog.rb:100)).

CRITICAL-3. Task 6 добавляет Ruby-тесты, которые не скомпилируются и, даже после исправления имени переменной, не загрузят зависимости.  
`SU_MCP_save_eval = ...` внутри метода Ruby трактует как константу и даст dynamic constant assignment ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:979)). Также план предлагает добавить только `handlers/eval`, но `eval.rb` на загрузке требует `SU_MCP::Helpers::Validation` ([eval.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/handlers/eval.rb:5)); текущий `test_dispatch_post_handshake.rb` этот helper не требует ([test](/opt/github/zinin/sketchup-mcp2/test/test_dispatch_post_handshake.rb:10)).

CRITICAL-4. Task 13 не поймает `-32010` в live smoke.  
`smoke_check.py` использует raw `SketchUpConnection.send_command`, а не Python FastMCP wrapper; при JSON-RPC error Ruby бросит `SketchUpError`, а `_maybe_skip_eval` в плане проверяет только возвращенный текст. Warehouse build все равно упадет на step 15. См. текущий `call()` ([smoke_check.py](/opt/github/zinin/sketchup-mcp2/examples/smoke_check.py:43)) и eval step ([smoke_check.py](/opt/github/zinin/sketchup-mcp2/examples/smoke_check.py:151)); плановый helper — [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:2277).

CRITICAL-5. Rename plan не доводит `su_mcp` до нуля, а финальный grep гарантированно провалится.  
Task 1 заменяет только `SU_MCP`, но не lowercase `su_mcp` в Ruby file headers, Python compat messages, release docs и других tracked файлах. Например [config.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/core/config.rb:1), [compat.py](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/compat.py:64), [release.md](/opt/github/zinin/sketchup-mcp2/docs/release.md:117). Финальная проверка требует пустой grep по `su_mcp` ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:2396)).

CRITICAL-6. `package.rb` оставляет скрытое состояние при ошибке сборки.  
`build_profile.rb` пишется в source tree и удаляется только на happy path ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1853), [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1891)). Если zip/copy падает, gitignored file останется и будет менять dev/runtime default. Нужен `ensure` или генерация сразу в staging dir.

CRITICAL-7. План сам себе противоречит по wire-protocol break.  
Вверху сказано “No wire-protocol breaks” ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:7)), но Task 11 правильно говорит, что `MIN_*` поднимаются до `0.2.0` и старые пары намеренно не handshake’ятся ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:2047)). Это надо исправить до передачи исполнителям.

### Concerns

CONCERN-1. “Every console line includes `[MCPforSU]`” не выполняется для DEBUG backtrace lines: `Logger.log_error` пишет backtrace напрямую через `write("    #{bt}")` ([logger.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/core/logger.rb:25)), а план добавляет prefix только в `log()`.

CONCERN-2. После “silent rescue cleanup” останутся тихие rescues: `Geometry.safe_abort` ([geometry.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/handlers/geometry.rb:13)) и `ClientState#peer_label` ([client_state.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/core/client_state.rb:53)). Если reviewer grep’ает `rescue StandardError`, это может снова всплыть.

CONCERN-3. Release docs не просто “недообновлены”, а противоречат новому решению о signed artifacts: старый раздел говорит, что EW отвергает pre-encrypted/signed `.rbz` и требует plain source ([release.md](/opt/github/zinin/sketchup-mcp2/docs/release.md:115)). План добавляет новый текст, но не удаляет/переписывает старый.

CONCERN-4. Settings dialog станет выше, но `HtmlDialog` остается `height: 360`, `scrollable: false`, `resizable: false` ([settings_dialog.rb](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/ui/settings_dialog.rb:30)). Новые секции могут обрезаться на Windows scaling.

CONCERN-5. Log-to-file требования слабее спецификации: parent dir “must exist or be creatable” в design ([design](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md:128)), но validator проверяет только non-empty ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1210)). `UI.openURL("file://#{path}")` также хрупок для Windows paths/spaces ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1615)).

CONCERN-6. Тесты часто проверяют текст/источник, а не поведение. `test_operation_names.rb` парсит файлы regex’ами, хотя design обещал mock model recorder ([design](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md:160)). Для Settings Task 8 прямо признает отсутствие headless coverage ([plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1284)).

CONCERN-7. Текущий checkout грязный: много untracked docs, `.gemini/`, `diff.patch`. План многократно использует `git add -A`; без предварительной чистки commits легко захватят мусор.

### Suggestions

SUGGESTION-1. Для eval default используйте sentinel: `read_default(..., nil)`, храните `@eval_enabled = nil` при отсутствии pref, добавьте `eval_enabled_default`, а UI грузите через effective `eval_enabled?`.

SUGGESTION-2. Реализуйте eval confirm как двухфазный flow: validate → если off→on, закрыть callback через timer → показать messagebox → при Yes сохранить, при No вызвать `applyState(previous)`.

SUGGESTION-3. Генерируйте `build_profile.rb` в staging tree или оборачивайте package body в `begin ... ensure FileUtils.rm_f(build_profile_path)`.

SUGGESTION-4. После rename делайте tracked grep по всем старым маркерам: `SU_MCP`, `su_mcp`, `SU_MCP_SERVER`, `Sketchup MCP Server`, `SketchupMCP`, и отдельно решите, какие исторические docs исключаются.

SUGGESTION-5. Добавьте тесты на реальные контракты: BuildProfile true/false при unset pref, explicit pref override, `package.rb` default variant без флага, raw smoke `SketchUpError(-32010)` skip, logger prefix на backtrace lines.

### Questions

QUESTION-1. Нужно ли полностью переписать старый `docs/release.md` EW-раздел под “оба `.rbz` через Trimble signing service”, или текущая заметка про EW rejecting encrypted artifacts все еще фактически верна?

QUESTION-2. Должен ли `src/sketchup_mcp/prompts.py` упоминать eval gate, чтобы встроенный MCP prompt не подталкивал LLM к eval без контекста?

QUESTION-3. Для manual GitHub-variant acceptance нужно ли явно очищать pref `MCPforSketchUp/eval_enabled`, иначе тест после warehouse-variant не доказывает build default?
---

## ccs-executor / glm — PARTIAL (extracted from reasoning trace)

> **Note:** the CCS run was terminated by the upstream after the model had produced its full structured analysis inside the reasoning channel but before the assistant streamed it as a `text` block. `output.txt` is therefore absent. The summary section below was extracted from the last `thinking` block in `raw.jsonl`. The 31 numbered findings preceding it (long-form analysis) are available in the raw log but not reproduced here for brevity — the summary captures all conclusions.

### Summary of findings:

**CRITICAL:**
1. `eval_enabled?` never reaches BuildProfile (CRITICAL-1) — `load_from_defaults!` always sets `@eval_enabled` to `false`, making the BuildProfile fallback dead code. The GitHub build would have eval disabled on fresh install.
2. `on_load_state` reads raw `eval_enabled` instead of `eval_enabled?` (CRITICAL-2) — even if CRITICAL-1 is fixed, the settings dialog would show the wrong checkbox state for fresh installs of the GitHub build.

**CONCERNS:**
1. Settings dialog height not adjusted for new fields (CONCERN-1)
2. No `eval_enabled-error` div in HTML — cancel feedback is invisible (CONCERN-2)
3. Checkbox state not actually rolled back on eval-cancel (CONCERN-3)
4. Python/Ruby compat.py error messages reference old `su_mcp_v...` filenames (CONCERN-4)
5. README sed misses standalone `su_mcp` without trailing `/` (CONCERN-5)
6. CLAUDE.md sed may miss some `SU_MCP` patterns (CONCERN-6)
7. Test variable name `SU_MCP_save_eval` looks odd after rename (CONCERN-7)

**SUGGESTIONS:**
1. Add explicit step to require handlers/eval in dispatch test (SUGGESTION-1)
2. Use `eval_enabled?` instead of `eval_enabled` in settings_dialog.rb `on_load_state` (SUGGESTION-2)
3. Add `eval_enabled-error` div to HTML or handle the cancel differently (SUGGESTION-3)
4. Update compat.py/compat.rb error messages to reference new filenames (SUGGESTION-4)

**QUESTIONS:**
1. How does SketchUp `read_default` behave with boolean false values? (QUESTION-1)

---

## ccs-executor / albb-deepseek (DeepSeek-V4 Pro, 1M context)

Теперь у меня полная картина. Ниже — детальная рецензия.

---

## Critical Issues

### CRITICAL-1: `BuildProfile` fallback — мёртвый код, github-вариант не работает

**Plan Task 4, Step 4.3(a)+(e); Spec §4.1**

`DEFAULTS[:eval_enabled] = false` означает, что `load_from_defaults!` всегда устанавливает `self.eval_enabled = !!raw_eval`, где `raw_eval` — всегда `true` или `false` (но никогда не `nil`). Метод `eval_enabled?` проверяет `unless @eval_enabled.nil?` — это условие **всегда истинно** после `load_from_defaults!`, поэтому fallback к `BuildProfile::EVAL_ENABLED_BY_DEFAULT` **никогда не достигается**. Github-вариант с `EVAL_ENABLED_BY_DEFAULT = true` ничем не отличается от warehouse — оба возвращают `false`.

**Исправление:** `DEFAULTS[:eval_enabled]` должно быть `nil`, а `load_from_defaults!` должен сохранять `nil` когда pref не установлен:

```ruby
# DEFAULTS
eval_enabled:   nil,  # "not configured" — falls back to BuildProfile

# load_from_defaults!
raw_eval = reader.read_default(SECTION, "eval_enabled", nil)
self.eval_enabled = raw_eval.nil? ? nil : !!raw_eval
```

Кроме того, `on_load_state` в `settings_dialog.rb` (Task 8, Step 8.2) использует `Config.eval_enabled` (attr_accessor), а не `Config.eval_enabled?`. При `@eval_enabled = nil` JS получит `null` → чекбокс unchecked даже для github-варианта. Нужно:

```ruby
eval_enabled: MCPforSketchUp::Core::Config.eval_enabled?,
```

Тест `test_defaults_include_eval_enabled_false` (Step 4.1) должен проверять `nil`, а не `false`.

### CRITICAL-2: `package.rb` — нет `ensure` для очистки `build_profile.rb`

**Plan Task 10, Step 10.2**

Если `Zip::File.open` бросает исключение (например, диск полон), шаги 4 (cleanup temp_dir) и 5 (rm build_profile_path) не выполняются. `build_profile.rb` остаётся в source tree. Следующий `git status` покажет untracked файл, который можно случайно закоммитить. Нужен `begin/ensure`:

```ruby
begin
  # ... zip logic ...
ensure
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  FileUtils.rm(build_profile_path) if File.exist?(build_profile_path)
end
```

### CRITICAL-3: `settings.html` — нет элемента `eval_enabled-error`, `clearErrors` не очищает `eval_enabled`

**Plan Task 8, Step 8.1; Spec §4.3**

Когда пользователь отклоняет confirmation messagebox для eval_ruby, Ruby-код отправляет `{ok: false, errors: {eval_enabled: 'Cancelled by user'}}`. JS `showErrors` ищет `document.getElementById('eval_enabled-error')` — такого элемента нет в HTML. Ошибка молчаливо теряется. Кроме того, `clearErrors` (строка 1375 плана) перечисляет только `['host', 'port', 'log_level', 'log_file_path']` — `eval_enabled` отсутствует.

Нужно:
1. Добавить `<div class="error" id="eval_enabled-error"></div>` в HTML после чекбокса eval_enabled
2. Добавить `'eval_enabled'` в массив `clearErrors`

### CRITICAL-4: `compat.py` и `compat.rb` — сообщения об ошибках ссылаются на старый `.rbz` filename

**Plan Task 12 — пропущено**

`src/sketchup_mcp/compat.py:64,81`:
```python
f"Reinstall su_mcp_v{MAX_RUBY}.rbz from the GitHub release. "
```

`su_mcp/su_mcp/core/compat.rb:66`:
```ruby
"Reinstall su_mcp_v#{MAX_PYTHON}.rbz from the GitHub release. "
```

После переименования файл называется `mcp_for_sketchup_v0.2.0-warehouse.rbz` / `mcp_for_sketchup_v0.2.0-github.rbz`. Ссылка `su_mcp_v0.2.0.rbz` ведёт на несуществующий файл. Sed-проходы в Task 1 и Task 12 не ловят эти строки, потому что они в нижнем регистре (`su_mcp`), а sed для Ruby меняет только `SU_MCP` (верхний регистр). Нужно явно обновить.

### CRITICAL-5: `CLAUDE.md` — sed-проход портит аннотации «to be renamed»

**Plan Task 12, Step 12.4**

Текущий `CLAUDE.md` (из system prompt) содержит:
```
Ruby SketchUp extension (`su_mcp/` — to be renamed `mcp_for_sketchup/`)
```

После sed `s|su_mcp/|mcp_for_sketchup/|g` получается:
```
Ruby SketchUp extension (mcp_for_sketchup/ — to be renamed mcp_for_sketchup/)
```

Это бессмыслица. Sed-проход нужно дополнить ручной правкой таких аннотаций (убрать «to be renamed»).

### CRITICAL-6: `test/run_all.rb` и test-файлы не по маске `test_*.rb` пропускаются sed

**Plan Task 1, Step 1.6**

Sed запускается только на `test/test_*.rb`. `test/run_all.rb` не содержит старых ссылок (проверено — только `__dir__` и `File.basename`), но **любой будущий test-helper файл с другим именем будет пропущен**. Это не баг для текущего состояния, но процессная дыра: план не проверяет, что `git grep` по всем файлам test/ возвращает ноль совпадений. Step 1.6 верифицирует только `test/` через `grep -r 'su_mcp\|SU_MCP' test/`, но sed не покрывает `run_all.rb` — если бы в нём были ссылки, grep бы их нашёл, а sed бы не исправил. Нужно расширить sed на `test/run_all.rb` или добавить явную проверку.

---

## Concerns

### CONCERN-1: `settings.html` — после отказа в confirmation диалог не перезагружает состояние

**Plan Task 8, Step 8.1–8.2; Spec §4.3**

Спецификация говорит: «the pref save is rolled back to its previous value before the dialog re-displays». План реализует отказ через `return` без вызова `update!` — runtime Config не меняется, prefs не пишутся. Но HTML-диалог **не перезагружает состояние** из Ruby. Чекбокс `eval_enabled` остаётся визуально checked, хотя save был отклонён. Пользователь видит расхождение. Нужно после отказа вызвать `on_load_state(dialog)` для возврата UI к сохранённому состоянию, либо передать `revert_eval_enabled: previous_value` в `onSaveResult`, чтобы JS сбросил чекбокс.

### CONCERN-2: `update!` keyword args — валидатор всегда передаёт все поля, nil-гарды проверены только для старых тестов

**Plan Task 4, Step 4.3(d); Task 7, Step 7.3**

Новый `SettingsValidator.validate` всегда возвращает все 6 полей в `normalized`. Новый `on_save` всегда передаёт все 6 полей в `update!`. Старые тесты (`test_update_persists_to_writer`, `test_update_mutates_runtime_before_raising`) передают только 3 старых поля. Ruby keyword arguments с defaults — обратно совместимы. Но `test_update_mutates_runtime_before_raising` ожидает `RuntimeError` от `FailingWriter`, и assertion проверяет ровно 3 writes. Новые поля с `nil` пропускают guards, writes остаётся из 3 элементов. OK. Но массового теста, где старый caller передаёт только `host:, port:, log_level:` и новый код корректно не трогает `eval_enabled` — нет. Стоит добавить.

### CONCERN-3: `sed 's/SU_MCP/MCPforSketchUp/g'` в `.rb` файлах — теоретический риск false positive в строках

**Plan Task 1, Step 1.4**

Если в строковом литерале (не в комментарии) встретится `SU_MCP` как подстрока, sed заменит и его. Пример: `"some_SU_MCP_data"` → `"some_MCPforSketchUp_data"`. После grep по коду таких случаев не найдено. Но план не содержит `grep` для верификации этой гипотезы. Защита: Step 1.11 (полный прогон тестов) поймает любые поломки.

### CONCERN-4: Старые тесты `test_logger.rb` — совместимость с новым префиксом

**Plan Task 3, Step 3.6**

План утверждает, что существующие тесты используют `assert_match(/...\z/, last_line)` и префикс «живёт до» проверяемого суффикса. Старый формат: `[timestamp] [LEVEL] msg`. Новый: `[timestamp] [MCPforSU] [LEVEL] msg`. Паттерны вида `/tool=create_component status=ok\z/` действительно продолжают работать — они не привязаны к началу строки. Проверено по `test/test_logger.rb` — все assertion используют `\z` без привязки к началу. OK.

### CONCERN-5: Строка `test_logger.rb:10-12` использует `SU_MCP::Core::Config` — sed исправит, но setup также требует сброса новых полей

**Plan Task 4, Step 4.3(f)**

План добавляет сброс `eval_enabled`, `log_to_file`, `log_file_path` в `setup` для `test_config.rb`. Но `test_logger.rb:10-12` тоже устанавливает `Config.host/port/log_level` — и **не сбрасывает** новые поля. Если тест Task 5 (`test_log_to_file_enabled_writes_to_path`) устанавливает `log_to_file = true`, а следующий тест в том же классе не сбрасывает — состояние утекает. План добавляет `teardown_log_to_file_state` метод, но он вызывается только если `teardown` явно его дёрнет. План добавляет `MCPforSketchUp::Core::Config.log_to_file = false` в `teardown`. OK, это правильно — `teardown` всегда сбрасывает. Но `eval_enabled` не сбрасывается в `teardown` logger-тестов. Если будущие тесты начнут менять `eval_enabled`, состояние утечёт.

### CONCERN-6: `docs/release.md` — не обновлён путь к `su_mcp/su_mcp.rb`

**Plan Task 12, Step 12.6**

План обновляет 4 пути в `docs/release.md` §1, но в текущем `docs/release.md` может быть больше ссылок на старые пути. План не делает полный `grep` по `docs/release.md` для выявления всех вхождений — полагается на глобальный grep в Step 12.8, который исключает `docs/superpowers/*` но не `docs/release.md`. `docs/release.md` не исключён из grep, так что оставшиеся ссылки будут найдены. Но sed-проход по release.md не делается — правки только ручные (4 конкретные строки). Надо либо добавить sed для release.md, либо явный grep.

---

## Suggestions

### SUGGEST-1: `package.rb` — валидация `extension.json` после сборки

После сборки `.rbz` стоило бы автоматически проверять, что `extension.json` внутри архива содержит правильный `product_id` и `version`. Одна команда `unzip -p ...rbz mcp_for_sketchup/extension.json | jq .product_id` в Step 10.4 спасёт от повторной отправки с неправильным ID.

### SUGGEST-2: Отдельный `build_profile.rb` в `test/` для тестирования github-пути

Поскольку `build_profile.rb` в gitignore и отсутствует при тестах, ветка `eval_enabled?` с `BuildProfile` вообще не тестируется (CRITICAL-1 это подтверждает). После исправления CRITICAL-1 стоит добавить временный `build_profile.rb` в test setup, который включает `EVAL_ENABLED_BY_DEFAULT = true`, и проверить, что `eval_enabled?` возвращает `true`. Иначе github-путь не имеет test coverage.

### SUGGEST-3: Константа `-32010` в Python — вынести в `compat.py`

Сейчас план определяет `_EVAL_DISABLED_CODE = -32010` в `tools.py` (Task 9, Step 9.3). Ruby хранит `EVAL_DISABLED_CODE = -32010` в `handlers/eval.rb` (Task 6, Step 6.3). Два независимых определения — риск расхождения при будущих изменениях. Предлагаю вынести в `compat.py` как `EVAL_DISABLED_CODE` и ссылаться из tools.py.

### SUGGEST-4: `test_operation_names.rb` — тест на нулевое покрытие edge-операций

`test_no_snake_case_op_labels_remain` перебирает **все** handler-файлы через `Dir[File.join(HANDLERS, "*.rb")]` и проверяет каждый `start_operation` через regex. Это хорошо покрывает регрессию, но если добавится новый handler-файл с `start_operation`, тест автоматически его проверит. Однако если новый handler использует `start_operation` с динамической строкой (не литерал), тест не найдёт паттерн — и это OK (false negative безопаснее false positive). Но отсутствие assertion о том, что **каждый** handler-файл имеет хотя бы одну операцию с Title Case — риск, что новый файл добавят и забудут про формат. Предлагаю отдельный тест: список известных handler-файлов обязан быть не пустым после `Dir[]`.

### SUGGEST-5: `sed` для `CLAUDE.md` — заменить на ручную правку

Для CLAUDE.md механический sed слишком груб (CRITICAL-5). Лучше описать в плане конкретные строки для правки, а не полагаться на sed. CLAUDE.md — короткий файл (~150 строк), ручная правка надёжнее.

---

## Questions

### QUESTION-1: `product_id` в `extension.json`

План Step 1.9 устанавливает `"product_id": "MCP_FOR_SKETCHUP"`. Это новый ID, не `SU_MCP_SERVER`. Подтверждено ли, что Trimble разрешит создать новый product (не update старого) через intake form? Spec §2 упоминает этот риск. Есть ли fallback-план, если intake form потребует привязки к старому `SU_MCP_SERVER`?

### QUESTION-2: `uv.lock` после version bump

План Step 11.9 делает `uv lock` после bump версии в `pyproject.toml`. Но `uv.lock` не коммитится в репо (проверено — `uv.lock` в `.gitignore` отсутствует, но существует ли он?). Нужно уточнить: `uv.lock` под версионным контролем? Если да — Step 11.9 корректен. Если нет — не нужно.

### QUESTION-3: `description` в `extension.json`

План Step 1.9 меняет `"description": "Model Context Protocol server for Sketchup"` → `"Model Context Protocol server for SketchUp"` (Su → Sk**U**). Но reviewer в v0.1.0 reject писал про «name», а не «description». Это намеренное исправление или случайная правка? Стоит явно отметить в плане.

### QUESTION-4: Совместимость `settings.html` с текущим dialog size

План Task 8, Step 8.1 добавляет 3 новых поля + 2 разделителя секций. Текущий dialog: `width: 380, height: 360`. С новым контентом высоты 360px может не хватить. План не меняет размеры диалога. Нужно протестировать визуально (Step 8.7 это покрывает). Но стоит упомянуть в плане, что размеры могут потребовать корректировки.

# Merged Design Review — Iteration 2 (2026-05-28)

**Source documents:**
- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`

**Review agents (5 dispatched, 3 completed):**
- `codex-executor` (gpt-5.5, xhigh) — **completed** ✓
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M context) — **completed** ✓
- `ccs-executor / albb-kimi` — **completed** ✓ (recovered from iter-1 stall — 23 tool calls, ~12 min)
- `ccs-executor / glm` — **failed** (upstream killed CCS during Explore subagent phase at 19:09; raw.jsonl stops at tool call #11 reading `su_mcp/package.rb`; 21+ min of silence after; no structured findings produced)
- `ccs-executor / albb-qwen` — **failed** (Alibaba MaaS Anthropic-bridge tenant has no Qwen model id; profile `qwen3.7-max[1m]` returns 400 `Model not exist.`; 9 alternative ids probed all 400/404 — same failure as iter-1)

**Iteration-2 reviewer set rationale:** user requested `default без albb-glm` after iter-1; albb-glm was already declared skipped per global preference.

---

## codex-executor (gpt-5.5, xhigh)

### Critical Issues

**Logger rewrite ломает API и возвращает debug-шум в консоль**

Цитата: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:549-590` предлагает заменить `core/logger.rb` блоком, где есть только `log`, `log_error`, `_emit`. В текущем коде `log_tool` существует и активно используется: `su_mcp/su_mcp/core/logger.rb:13-18`.

Проблема: если исполнитель буквально применит блок из плана, `Logger.log_tool` исчезнет, и `Application`/`Server` начнут падать. Вторая проблема там же: текущий код пишет backtrace только при `Config.log_level == "DEBUG"` и максимум 3 строки (`su_mcp/su_mcp/core/logger.rb:25-26`), а план пишет весь backtrace всегда (`docs/...warehouse-resubmit.md:566-574`). Это прямо конфликтует с требованием reviewer-а убрать debug clutter из общей Ruby Console.

Fix direction: в Step 3.3 сохранить `log_tool` без изменения, а backtrace-ветку оставить gated: `return unless Config.log_level == "DEBUG" && error.backtrace`, с `first(3)`, но через `_emit("#{LINE_PREFIX} ...")`.

**eval-confirm timer path не защищён rescue и пропускает restart flow**

Цитата: deferred-блок `UI.start_timer` в `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1877-1901`; общий `rescue` находится снаружи метода на `1930-1938`.

Проблема: исключения внутри timer callback не попадут в этот outer rescue. Если `confirm_eval_enable`, `Config.update!` или `dialog.execute_script` упадут, UI останется в неопределённом состоянии. Плюс confirmed path сохраняет host/port (`1880-1887`), но не выполняет обычную ветку `need_restart`/`dialog.close` (`1905-1928`). Если пользователь одновременно включает eval и меняет port, сервер останется на старом runtime config без restart prompt.

Fix direction: вынести нормальную persist/restart-логику в helper и вызывать её после `Yes`; тело timer callback завернуть в собственный `begin/rescue`, логировать `settings_dialog.eval_confirm`, делать безопасный `onSaveResult(_general)` и rollback `applyState`.

**`URI::File.build` не делает то, что утверждает план**

Цитата: дизайн утверждает, что `URI::File.build(path: File.expand_path(...)).to_s` “properly escapes spaces, non-ASCII characters, and Windows drive-letter paths” (`docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md:152`); план повторяет это в `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:1963-1975`.

Проблема: на локальном Ruby 3.2.3 `URI::File.build(path: "/tmp/a b.log")` raises `URI::InvalidComponentError`; Windows drive-letter paths also need special handling. Значит Show Log может падать именно на кейсах, ради которых выбран этот API.

Fix direction: добавить helper, который нормализует `\` → `/`, для Windows добавляет leading slash перед `C:/...`, затем применяет `URI::DEFAULT_PARSER.escape(path)` и только потом `URI::File.build(path: escaped)`. Покрыть тестом path with spaces/non-ASCII.

**`build_profile.rb` всё ещё может остаться после failure**

Цитата: `File.write(build_profile_path, ...)` выполняется до `begin/ensure` (`docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:2253-2267`), а cleanup начинается только в `ensure` на `2295-2298`.

Проблема: если `File.write` создаст/частично создаст файл и затем упадёт, `ensure` не сработает. Это сохраняет тот самый hidden state, который план считает закрытым.

Fix direction: объявить `build_profile_path`/`temp_dir` до `begin`, но сам `File.write` перенести внутрь `begin`; `ensure` должен покрывать генерацию, staging, zip и post-build cleanup.

**Strict grep сам себе противоречит**

Цитата: release.md addition explicitly inserts `SU_MCP_SERVER` at `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:2671-2672` and `2685-2686`, но Step 12.8 затем запрещает `SU_MCP_SERVER` in non-historical tracked files (`2732-2744`).

Проблема: Task 12 не может пройти как написан. `docs/release.md` не исключён из grep, значит strict check будет падать на текст, который сам план только что добавил.

Fix direction: либо убрать literal `SU_MCP_SERVER` из user-facing `docs/release.md` (“prior v0.1.0 listing” без ID), либо явно считать `docs/release.md` историческим исключением. Лучше первое, чтобы reviewer-facing docs не держали старый first-party-looking ID.

**Files lists неполные при explicit-path commit policy**

Цитата: policy требует staging “drawn from this task’s Files header” (`docs/superpowers/plans/2026-05-28-warehouse-resubmit.md:15-25`). Но Task 4 Files перечисляет только `config.rb`, `main.rb`, `test_config.rb` (`696-700`), хотя Step 4.0 создаёт `test/support/config_reset.rb` и меняет `test_logger.rb`/`test_application.rb` (`709-731`). Аналогично: Task 8 Step 8.3 меняет `core/application.rb`, но Files header его не содержит (`1581-1584`, `1961`); Task 9 меняет `compat.py` и `prompts.py`, но Files header содержит только `tools.py`/`tests/test_tools.py` (`2046-2048`, `2092`, `2158`); Task 10 создаёт `test/test_package_default_variant.rb` без Files entry (`2216-2219`, `2361`); Task 13 создаёт `tests/test_smoke_helpers.py` без Files entry (`2770-2772`, `2853`).

Проблема: исполнитель, следуя policy, легко не застейджит новые/изменённые файлы, и коммиты будут неполными.

Fix direction: обновить каждый Files header так, чтобы он был authoritative для всех шагов задачи, включая newly created tests and helper files.

### Concerns

**Оставшиеся silent-looking rescues могут снова привлечь reviewer-а**

`su_mcp/su_mcp/helpers/validation.rb:57` содержит `Integer(v.to_s, 10) rescue nil`; `su_mcp/su_mcp/ui/settings_dialog.rb:126-127` silently swallows secondary `execute_script` failure. Они не эквивалентны скрытию production bugs, но reviewer уже отметил “silent rescues”. Лучше заменить на explicit `begin/rescue ArgumentError` для validation и хотя бы `Logger.log("DEBUG", ...)` для secondary dialog failure.

**`ConfigReset` и Step 4.3(f) конфликтуют**

Step 4.0 говорит заменить ad-hoc resets shared helper-ом (`docs/...warehouse-resubmit.md:727-742`), но Step 4.3(f) снова предлагает ручной `setup` с полями (`956-966`). Это не blocker, но создаёт ненужную развилку. Удалить 4.3(f) или переписать как “verify setup calls `ConfigReset.reset_all!`”.

**`sed -i` не переносим на macOS**

План многократно использует GNU-style `sed -i` без backup suffix (`docs/...warehouse-resubmit.md:96-105`, `132-133`, `2540-2541`, `2716`). На macOS/BSD sed это падает. Учитывая, что SketchUp dev often happens on macOS, лучше заменить на `ruby -pi -e`/`perl -pi -e` или явно указать GNU sed prerequisite.

**Boolean prefs слишком доверяют persisted storage**

`raw_eval.nil? ? nil : !!raw_eval` и `!!raw_l2f` (`docs/...warehouse-resubmit.md:896-905`) превратят persisted string `"false"` в `true`. Settings пишет booleans, но prefs считаются untrusted. Надёжнее иметь `coerce_bool_pref(value, default:)`, принимающий только `true`/`false`, иначе WARN + default/sentinel.

### Suggestions

Добавить package test, который открывает default-built `.rbz` и проверяет не только filename `*-warehouse.rbz`, но и `core/build_profile.rb` с `EVAL_ENABLED_BY_DEFAULT = false`.

Для `Core.const_defined?` in `eval_enabled?` использовать non-inherited lookup: `Core.const_defined?(:BuildProfile, false)` and `Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT, false)`.

Обновить Task 13 commit message: сейчас helper ловит `SketchUpError(-32010)`, а commit text говорит про text detection / `[-32010]` format (`docs/...warehouse-resubmit.md:2907-2910`).

### Questions

Должен ли `docs/release.md` быть user-facing и проходить strict legacy grep, или допускается хранить в нём literal old product_id? Сейчас план одновременно требует оба поведения.

Нужна ли отдельная manual acceptance строка именно для macOS `UI.messagebox` modality? Windows quirk покрыт, но macOS modal behavior для HtmlDialog + deferred native dialog не зафиксирован.
---

## ccs-executor / albb-deepseek (DeepSeek-V4 Pro, 1M context)

Теперь у меня достаточно информации для написания ревью. Соберу findings.

---

### Critical Issues

**CRITICAL-1: Step 4.3(f) противоречит Step 4.0 — два разных подхода к reset Config state**

Plan:1687-1690 (Step 4.0) предписывает заменить ad-hoc `setup` на `ConfigReset.reset_all!`. Но Plan:956-965 (Step 4.3(f)) всё ещё показывает ручной список `C.host = nil; C.port = nil; ...` с комментарием «extend setup cleanup in tests». Имплементор не поймёт, что делать: использовать `ConfigReset.reset_all!` (как велит Step 4.0) или дополнить ручной список (как велит Step 4.3(f)). Это не numbering issue — два параграфа предписывают взаимоисключающие действия для одного и того же `setup`.

**Fix:** Удалить Step 4.3(f) целиком. `ConfigReset.reset_all!` из Step 4.0 уже покрывает все поля.

---

**CRITICAL-2: Timer callback в двухфазном confirm flow не имеет rescue — исключение улетает в SketchUp timer dispatch**

Plan:1877-1901. `::UI.start_timer(0, false)` callback содержит вызовы `confirm_eval_enable`, `Config.update!`, `dialog.execute_script`, `js_safe_json`. Если ЛЮБОЙ из них кинет исключение (например, `JSON.generate` упадёт на невалидном объекте, `dialog.execute_script` упадёт на закрытом диалоге, `Config.update!` упадёт на `write_default`), оно propagates в SketchUp timer dispatch, где НЕ ловится. Внешний `rescue StandardError` в `on_save` (Plan:1930) не покрывает timer callback — это другой стек.

Дизайн §4.3 обсуждает только `UI.messagebox` hang на Windows, но не упоминает exception safety внутри timer callback'а. Для сравнения, существующий `on_save` (текущий код `settings_dialog.rb:104-111`) тоже имеет эту проблему для restart prompt, но там только `::UI.messagebox` и `Application.restart` — узкий surface. Новый confirm flow добавляет `Config.update!` + `dialog.execute_script` × 2 — wider surface.

**Fix:** Обернуть тело timer callback'а в `begin/rescue StandardError => e; Logger.log_error("settings_dialog.eval_confirm", e); end`.

---

**CRITICAL-3: Post-build верификация в `package.rb` не проверяет поле `name`**

Plan:2305-2316 (Step 10.2). Ensure-block проверяет `product_id` и `version`, но НЕ `name`. Reviewer rejected v0.1.0 именно из-за имени («SketchUp MCP Server» implies first-party). Если `name` регрессирует (merge conflict resolution mistake, забыли обновить в Task 1 Step 1.9), ре-сабмит снова провалится, а post-build check молча пропустит. `extension.json:165` содержит `"name": "MCP Server for SketchUp"` в плане — это правильное значение, которое надо верифицировать.

**Fix:** Добавить в Step 10.2 блок `unless meta["name"] == "MCP Server for SketchUp"; raise ...; end`.

---

**CRITICAL-4: `#peer_label` fallback silently изменён с `"unknown"` на `"<unknown>"`**

Plan:468-481 (Step 2.11.b) говорит: «Preserve the existing fallback return `"<unknown>"`». Но текущий код `client_state.rb:57` возвращает `"unknown"` (без angle brackets). Это НЕ preservation — это behavioural change. Значение используется в `@label = "##{id}[#{peer_label(sock)}]"` (строка 13), так что лейблы клиентов в логах изменятся с `#0[unknown]` на `#0[<unknown>]`. Дизайн §7 таблица тоже показывает `"<unknown>"` как «After», но в колонке «Before» должно быть `"unknown"` (сейчас там написано то же самое `<unknown>` — таблица некорректна).

**Fix:** В дизайне §7 исправить колонку «Before» для `ClientState#peer_label` на `"unknown"`. В плане Step 2.11.b убрать слово «Preserve» и честно написать: «Change fallback from `"unknown"` to `"<unknown>"` for consistency with other placeholder labels.»

---

### Concerns

**CONCERN-1: Новые test-файлы, создаваемые в середине задач, отсутствуют в заголовках Files**

Commit policy (Plan:15-25) требует explicit-path `git add`, derived from task Files header. Но несколько новых test-файлов создаются в steps, а не перечислены в Files:

| Task | Step | Создаваемый файл | В Files? |
|------|------|-----------------|----------|
| Task 4 | 4.5.a | `test/test_build_profile_fixture.rb` | Нет |
| Task 10 | 10.6.a | `test/test_package_default_variant.rb` | Нет |
| Task 13 | 13.4.a | `tests/test_smoke_helpers.py` | Нет |

Имплементор, следуя commit policy буквально, пропустит эти файлы при `git add`. Для сравнения, `test/test_operation_names.rb` (Task 2) и `test/support/config_reset.rb` (Task 4) честно перечислены в Files.

**Fix:** Добавить пропущенные файлы в заголовки Files соответствующих задач.

---

**CONCERN-2: `test_package_default_variant.rb` делает `Dir.chdir` без восстановления**

Plan:2366-2377 (Step 10.6.a). Тест делает `Dir.chdir(File.expand_path("../mcp_for_sketchup", __dir__))`, но НЕ сохраняет и НЕ восстанавливает `Dir.pwd`. Minitest не изолирует рабочие директории между тестами — другие тесты, запущенные после этого, будут выполняться из `mcp_for_sketchup/`, что сломает относительные пути (`require_relative "../mcp_for_sketchup/..."`).

**Fix:** Сохранить `Dir.pwd` в `setup`, восстановить в `teardown`. Или использовать `Dir.chdir(...) { ... }` с блоком.

---

**CONCERN-3: `test_smoke_helpers.py` через `importlib` выполняет побочные эффекты `smoke_check.py`**

Plan: 2863-2869 (Step 13.4.a). `spec.loader.exec_module(_smoke)` выполняет ВЕСЬ `smoke_check.py` как модуль, включая `sys.path.insert(0, ...)` на строке 36 оригинального файла. Это modifies `sys.path` глобально для всего test run. Также выполняются `print` statement'ы если они есть на module level.

**Fix:** Добавить guard в `smoke_check.py`: `if __name__ == "__main__":` для `sys.path` манипуляции. Или monkeypatch `sys.path` в тесте до и восстановить после.

---

**CONCERN-4: Дизайн §7 — `ClientState#peer_label` колонка «Before» некорректна**

Design:182 — в колонке «Before» написано `rescue StandardError; # ignore; end; "<unknown>"`, но текущий код возвращает `"unknown"` (без angle brackets). Это та же проблема что CRITICAL-4, но на уровне дизайна.

---

**CONCERN-5: `run_edge_op` error message изменится вместе с label**

Plan:360: «Note: `run_edge_op` itself uses `op_name` for both the start_operation label AND the error message». Текущий код `operations.rb:199`:
```ruby
"#{op_name}: no edges could be cut on target_id=#{entity_id} ..."
```
После замены `"chamfer_edges"` → `"Chamfer Edges"`, ошибка станет `"Chamfer Edges: no edges could be cut..."`. Это читаемо, как и отмечено в плане. Но это также behavioural change в JSON-RPC error message, который Python-клиент может парсить. Smoke test проверяет только `assert_includes(result, "...")` на ошибки — не завязан на точный формат. Но если кто-то в будущем regex-парсит эти сообщения, смена формата сломает парсер. Минорно.

---

**CONCERN-6: Smoke check eval skip: commit message описывает неверный механизм**

Plan:2903-2912 (Step 13.6 commit message): «Detects either the actionable plain-text disabled message (from Python wrapper's -32010 routing) or the [-32010] format_error form (other tools)». Но `_maybe_skip_eval` (Step 13.2) ловит `SketchUpError` с `e.code == EVAL_DISABLED_CODE`, а не текст. Commit message описывает поведение, которое было в CRITICAL-4 ДО исправления. После исправления CRITICAL-4, `_maybe_skip_eval` работает через `SketchUpError.code`, а не через текст. Commit message устарел относительно кода, который он коммитит.

---

### Suggestions

**SUGGESTION-1: `truthy?` в валидаторе принимает `nil` как `false`**

Plan:1538-1541. `truthy?(nil)` → `nil.to_s == "true"` → `"" == "true"` → `false`. Это ок. Но `Sketchup.read_default` для отсутствующего ключа с дефолтом `nil` возвращает `nil`. Когда `on_save` отправляет `eval_enabled: false` из HTML checkbox, валидатор получает строку `"false"`, что корректно. Но если клиент (не через UI) вызовет `update!` с `eval_enabled: nil`, `truthy?(nil)` → `false`, что совпадает с sentinel. Семантика «nil значит unset» теряется на уровне валидатора — он нормализует nil в false. Это не баг (на уровне UI unset не бывает), но стоит документировать это различие в комментарии к `truthy?`.

**SUGGESTION-2: Step 14.7 step 7a — `Sketchup.write_default("MCPforSketchUp", "eval_enabled", nil)`**

Plan:3003-3004. Вызов `write_default("MCPforSketchUp", "eval_enabled", nil)` — это валидный API для удаления ключа из prefs? Согласно SketchUp Ruby API документации, `write_default(section, key, nil)` эквивалентно удалению ключа. Это правильный способ сбросить pref. Но план не объясняет это — стоит добавить краткий комментарий.

**SUGGESTION-3: `test_build_profile_fixture.rb` — fixture загружается через `load`, не `require`**

Plan:1034. `load @tmp.path` вместо `require`. Это правильно — `load` всегда перезагружает файл, `require` кеширует по пути. Но если тест запущен дважды в одном процессе (маловероятно для minitest), `remove_const` + `load` сработает, а `require` — нет.

**SUGGESTION-4: Step 8.2 — `on_save` normal path не перезагружает `load_state_payload` после save**

Plan:1916 — после `Config.update!` и `dialog.execute_script("window.onSaveResult(...)")`, диалог закрывается через `dialog.close`. Но состояние диалога НЕ обновляется через `applyState` после успешного save (в normal path). Это существующее поведение текущего кода (`settings_dialog.rb:94-102`) — диалог просто закрывается после успешного save, и пользователь видит новый state при следующем открытии. Это ок, но отличается от confirm-пути, где `applyState` вызывается явно. Разница объяснима: confirm-путь НЕ закрывает диалог (пользователь остаётся в диалоге после Yes/No), а normal path закрывает.

---

### Questions

**QUESTION-1: Должен ли `product_id` в `extension.json` проверяться и в CI?**

Post-build verify в `package.rb` проверяет `product_id` только при сборке. Если кто-то случайно изменит `extension.json` в коммите, это не будет поймано до момента сборки (Step 14.3). Стоит ли добавить статический тест (например, в `test/run_all.rb`), который проверяет `extension.json` на правильный `product_id` и `name`? Это даст более ранний feedback, чем post-build verify.

**QUESTION-2: Поведение `UI.messagebox` на macOS для двухфазного confirm flow**

Дизайн §4.3 и план Step 8.2 обсуждают Windows quirk с `UI.messagebox`-inside-callback. На macOS `UI.messagebox` показывает app-modal sheet. Вызов из `UI.start_timer(0, false)` должен работать, поскольку таймер покидает callback frame. Но есть ли риск, что messagebox появится BEHIND других окон (аналогично Windows)? Проверялось ли это поведение на macOS?

**QUESTION-3: Судьба `su_mcp_v0.1.0.rbz` в git history**

После Task 1 (rename), `git mv su_mcp mcp_for_sketchup` перемещает директорию. Старые `.rbz` файлы внутри `su_mcp/` (если есть) тоже переедут. Нужно ли явно упомянуть в плане очистку старых `.rbz` из `mcp_for_sketchup/` до коммита? Или они уже в `.gitignore`?

---

## ccs-executor / albb-kimi

Провёл ревью обоих документов (design + plan) и сделал проход по кодовой базе. Ниже — новые замечания, которые не были покрыты 32 уже-решёнными issues из iter-1.

---

### Critical Issues

**1. Task 8 Files header пропускает `application.rb` при существенном изменении `show_log` (Step 8.3)**

- **Цитата**: Task 8 Files (plan, ~lines 1582–1586) перечисляет только `settings.html`, `settings_dialog.rb`, `test/test_settings_dialog.rb`. Но Step 8.3: «Edit `mcp_for_sketchup/mcp_for_sketchup/core/application.rb` — replace `show_log`».
- **Обоснование**: `show_log` получает полностью новую реализацию: добавляется `require "uri"`, ветвление на `log_to_file`, `URI::File.build`. Это логика, не механический rename. При explicit-paths commit policy (iter-1 CONCERN-7) файл не попадёт в `git add`, и пункт меню «Show Log» останется сломанным в коммите.
- **Направление исправления**: добавить `mcp_for_sketchup/mcp_for_sketchup/core/application.rb` в Task 8 Files header.

**2. Новые файлы тестов отсутствуют в Headers «Files» своих задач**

- **Цитата**:
  - `test/support/config_reset.rb` (Step 4.0) — не в Task 4 Files.
  - `test/test_build_profile_fixture.rb` (Step 4.5.a) — не в Task 4 Files.
  - `test/test_package_default_variant.rb` (Step 10.6.a) — не в Task 10 Files.
  - `tests/test_smoke_helpers.py` (Step 13.4.a) — не в Task 13 Files.
- **Обоснование**: Без включения в `Files` header коммит-шаг с explicit-paths `git add` пропустит эти файлы. Без `config_reset.rb` сломаются `test_config.rb`/`test_logger.rb`/`test_application.rb`. Без `test_build_profile_fixture.rb` — не покрыт github-путь `eval_enabled?`. Без остальных — теряется coverage новых фич.
- **Направление исправления**: добавить каждый файл в `Files` header соответствующего task.

**3. Несоответствие между `ConfigReset` helper и реальным setup в `test_config.rb`**

- **Цитата**: Step 4.0 требует заменить setup на `ConfigReset.reset_all!` в `test_config.rb`, `test_logger.rb`, `test_application.rb`. Но Step 4.3(f) показывает inline setup в `test_config.rb` (ручной сеттер для каждого поля).
- **Обоснование**: Если implementer следует Step 4.3(f) literally, `ConfigReset` не будет использован в `test_config.rb`, что противоречит инструкции Step 4.0 и оставляет расхождение в подходе.
- **Направление исправления**: в Step 4.3(f) заменить inline setup на `ConfigReset.reset_all!`, а `test/test_application.rb` и `test/test_logger.rb` добавить в Task 4 Files header.

---

### Concerns

**1. `sed -i` в plan не портируем на macOS (BSD sed)**

- **Затронутые шаги**: Task 1.4, Task 1.6, Task 12.1, Task 12.7 (`docs/superpowers/plans/...` lines 88–106, 130–134, 2539–2541, 2716). GNU sed принимает `sed -i 's/.../.../g'`, BSD sed требует `sed -i.bak` и не позволяет объединять `-i` с expression-аргументами в одном флагом.
- **Обоснование**: review focus явно упоминает «command runnability (find/sed/awk portability)». Если план будет выполняться на macOS (где работает SketchUp), sed-команды упадут.

**2. `test_settings_dialog.rb` помечен «Modify», но шагов модификации нет**

- **Цитата**: Task 8 Files header говорит «Modify: `test/test_settings_dialog.rb`». Однако в шагах Task 8 единственное упоминание — Step 8.4 «Verify existing test_settings_dialog still passes».
- **Обоснование**: Новые поля диалога (`eval_enabled`, `log_to_file`, `log_file_path`) не получают тестового покрытия в `test_settings_dialog.rb`. Единственные тесты — в `test_settings_validation.rb`. Ruby-сайд `load_state_payload` и `on_save` (eval transition) остаются без unit-тестов. Либо нужно добавить шаги модификации, либо убрать «Modify» из header.

**3. `test_log_to_file_failure_falls_back_silently` не проверяет DEBUG fallback-сообщение**

- **Цитата**: Step 5.1 (`test/test_logger.rb`): тест проверяет только «не кидает исключение». Design §5.2 обещает «one-shot DEBUG console line» при падении записи в файл.
- **Обоснование**: План гарантирует пользователю, что при ошибке записи в лог-файл будет видимое DEBUG-сообщение. Тест не проверяет его наличие, что позволяет регрессию (например, забыть вызвать `_emit_console` в fallback).

**4. PATTERNS в Task 12.8 не ловит «SketchUp MCP Server» (capital U)**

- **Цитата**: `PATTERNS='su_mcp|SU_MCP|Sketchup MCP Server|SketchupMCP|SU_MCP_SERVER'` (Task 12.8, line 2733). «SketchUp» с заглавным U отсутствует.
- **Обоснование**: Если где-то в коде осталась форма «SketchUp MCP Server», grep её пропустит. Это противоречит цели строгого grep-контроля.

**5. Smoke check `eval_skipped` — неясный scope счётчика**

- **Цитата**: Step 13.3 просит добавить `eval_skipped = 0` «at the top of the run» и инкрементировать внутри обёрнутых eval-вызовов. Но план не показывает полный `main()` контекст.
- **Обоснование**: Если `eval_skipped` объявлен в одной async-функции, а `_maybe_skip_eval` вызывается в другом scope (или внутри вложенных функций), Python требует `nonlocal eval_skipped`, иначе `UnboundLocalError`.

---

### Suggestions

**1. Заменить `sed -i` на portable аналог**

Вместо `sed -i 's/.../.../g'` использовать `sed -i.bak 's/.../.../g' && rm -f *.bak`, либо Ruby one-liner (`ruby -pi -e 'gsub(...)'`), либо встроенные Edit-операции (как уже сделано для `CLAUDE.md` в Step 12.4). Это устранит portability-риск без потери функциональности.

**2. Добавить assert на DEBUG fallback в `test_log_to_file_failure_falls_back_silently`**

В `test/test_logger.rb` (Step 5.1) дополнить тест проверкой captured stdout: убедиться, что строка содержит `[MCPforSU] [DEBUG] log file write failed...`. Это гарантирует, что fallback-путь в `Logger.append_to_file` не будет silently сломан в будущем.

**3. Добавить `SketchUp MCP Server` (capital U) в Task 12.8 PATTERNS**

Обновить `PATTERNS` на:
```bash
PATTERNS='su_mcp|SU_MCP|Sketchup MCP Server|SketchUp MCP Server|SketchupMCP|SU_MCP_SERVER'
```
Это покрывает обе вариации capitalization.

**4. Добавить unit-тест для `load_state_payload` shape в Task 8**

Даже если HTML-диалог не тестируется headless, Ruby-метод `SettingsDialog.load_state_payload` возвращает чистый Hash — его можно тестировать без SketchUp API. Добавить в `test/test_settings_dialog.rb` проверку, что `load_state_payload` содержит ключи `:log_to_file`, `:log_file_path`, `:eval_enabled` с корректными типами. Это дешёвое покрытие для регрессии «забыли новое поле в payload».

---

### Questions

**1. Task 8 `application.rb`: должен ли он остаться в Task 8 или быть вынесен в отдельный task?**

`show_log` в `application.rb` (Step 8.3) изменяет core-логику (menu action), а не UI. Возможно, логичнее было бы поместить его в Task 5 (Logger), чтобы Task 8 был чисто про HTML/Ruby dialog wiring. Какова здесь интенция автора — оставить в Task 8 или рефакторить?

**2. `test_settings_dialog.rb`: intended ли «Modify» в Files header, если реальная модификация отсутствует?**

Если план не предполагает добавление тестов для новых полей в `test_settings_dialog.rb`, то «Modify» в Files header вводит в заблуждение. Либо нужно добавить шаги модификации, либо заменить на «Read/Verify». Какой подход предпочтительнее?

**3. Гарантирован ли scope `eval_skipped` в `smoke_check.py`?**

В Step 13.3 `eval_skipped += 1` выполняется внутри async-функции. Если обёрнутые eval-вызовы происходят внутри вложенных функций или классов (вместо прямого `main()` scope), потребуется `nonlocal eval_skipped`. План не показывает полную структуру `main()`. Можете ли подтвердить, что в текущей реализации `smoke_check.py` счётчик будет в той же области видимости, что и вызовы `_maybe_skip_eval`?

---

## ccs-executor / glm — FAILED

CCS run was killed by upstream during the Explore subagent phase at 19:09 (~5 minutes into the run). `raw.jsonl` shows the Explore subagent reading source files up to tool call #11 (`su_mcp/package.rb`), then silence for 21+ minutes. The Explore subagent never returned to the parent model; the parent never produced any review output. No structured findings extractable from the reasoning trace this time (unlike iter-1 where structured findings were buried in thinking blocks).

**raw.jsonl:** `/home/zinin/.claude/ccs-interaction/2026-05-28-19-04-19-495555-design-review-warehouse-resubmit-iter-2-glm/raw.jsonl` (593 KB, 118 lines, last write 19:09)

Recommendation: drop `glm` from iter-2 — proceed with codex + albb-deepseek + albb-kimi findings.

---

## ccs-executor / albb-qwen — FAILED

Repeat of iter-1 failure. Profile `~/.ccs/albb-qwen.settings.json` still declares `ANTHROPIC_MODEL=qwen3.7-max[1m]` which returns HTTP 400 `Model not exist.` on the Alibaba MaaS Anthropic-bridge tenant. Dispatching agent probed 9 alternative Qwen model ids (`qwen3-max`, `qwen-max`, `qwen3-max-latest`, `qwen-max-latest`, `qwen3.5-max`, `qwen3-max[1m]`, `qwen-plus`, `qwen3-coder-plus`) — all 400/404. The tenant has `glm-5.1`, `MiniMax-M2.5`, and (per other profiles) Kimi + DeepSeek active, but no Qwen reachable. CCS model catalog cache has zero qwen entries.

**Suggested fix (later, out of scope for iter-2):** drop `albb-qwen` from the reviewer panel, OR switch the profile's `ANTHROPIC_BASE_URL` to a tenant that publishes Qwen (e.g. DashScope-native Anthropic bridge if user obtains a token).

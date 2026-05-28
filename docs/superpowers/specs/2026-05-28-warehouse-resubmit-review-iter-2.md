# Review Iteration 2 — 2026-05-28

## Источник

- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`
- Review agents:
  - `codex-executor` (gpt-5.5, xhigh) — completed.
  - `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M context) — completed.
  - `ccs-executor / albb-kimi` — completed (recovered after iter-1 stall; 23 tool calls, ~12 min).
  - `ccs-executor / glm` — failed (upstream killed CCS during Explore subagent phase; no structured findings produced).
  - `ccs-executor / albb-qwen` — failed (Alibaba MaaS Anthropic-bridge tenant returns 400 `Model not exist.` for all probed Qwen profiles; same failure as iter-1).
- Merged output: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md` (committed in round-1 commit `644d193`).
- Round-1 partial commit: `644d193 docs: review iter 2 — partial auto-fixes round 1 (warehouse-resubmit)` applied 13 of 25 AUTO fixes (design tier + Files headers + 1× plan-content). This file is the round-2 + final decision log; auto-fixes were split across two commits because the round-1 work hit the session's context budget before the plan tier could be patched.

## Замечания

### [CRITICAL-1] Logger rewrite ломает API и шумит DEBUG-backtrace на всех уровнях

> «Step 3.3 предлагает заменить `core/logger.rb` блоком, где есть только `log`, `log_error`, `_emit`. В текущем коде `log_tool` существует и активно используется (8 call sites в `application.rb` + `server.rb`). Если исполнитель буквально применит блок, `Logger.log_tool` исчезнет, и сервер начнёт падать. Вторая проблема: текущий код пишет backtrace только при `Config.log_level == "DEBUG"` и максимум 3 строки, а план пишет весь backtrace всегда — прямой конфликт с warehouse-rejection требованием убрать debug clutter из общей Ruby Console.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 1 (design `§5.1`, commit `644d193`) + round 2 (plan Step 3.3, this commit).
**Ответ:** В дизайне сохранено описание shared `_emit` private helper'а с явным указанием на сохранение `log_tool` API и DEBUG-gated `first(3)` backtrace. В плане Step 3.3 заменён full-module replacement на четыре explicit per-method edit'а (LINE_PREFIX constant; `self.log` body rewrite через `_emit`; `self.log_error` route backtrace continuation через `_emit("#{LINE_PREFIX}     #{bt}")` сохраняя DEBUG-gate и `first(3)` cap; `self.write` → private `self._emit`). Явная директива «Do NOT touch `self.log_tool`» с перечислением 8 call sites. Тест `test_log_error_backtrace_lines_carry_prefix` обновлён: `Config.log_level = "DEBUG"` перед raise + ensure-restore — иначе backtrace gate'ил бы вывод и `refute_empty bt_lines` падало бы, провоцируя кого-то ослабить assertion и замаскировать реальную регрессию.
**Действие:** design §5.1 (round 1); plan Step 3.3 — четыре explicit edit'а + comment про DEBUG-gate test pattern (round 2).

---

### [CRITICAL-2] Timer callback в двухфазном confirm flow не имеет rescue + skip restart flow

> «`::UI.start_timer(0, false)` callback содержит вызовы `confirm_eval_enable`, `Config.update!`, `dialog.execute_script`, `js_safe_json`. Если любой кинет исключение, оно propagates в SketchUp timer dispatch, где НЕ ловится. Внешний `rescue StandardError` в `on_save` не покрывает timer callback — это другой стек. Плюс confirmed path сохраняет prefs, но не выполняет обычную ветку `need_restart`/`dialog.close` — пользователь, одновременно включающий eval и меняющий port, останется на старом runtime config без restart prompt.»

**Источник:** codex-executor + ccs-executor/albb-deepseek (consensus).
**Статус:** Автоисправлено — round 1 (design `§4.3`, commit `644d193`) + round 2 (plan Step 8.2, this commit).
**Ответ:** В дизайне `§4.3` уже описан timer-internal rescue + `persist_and_finalize` helper (round 1). В плане Step 8.2 имплементирован: (a) shared `self.persist_and_finalize(dialog, normalized, current_runtime, override_eval_enabled: nil)` private helper, через который проходит и нормальный путь, и Yes-ветка confirm flow (Yes передаёт `override_eval_enabled: true`); (b) тело timer-block обёрнуто в `begin/rescue StandardError => e; Logger.log_error("settings_dialog.eval_confirm", e); ... applyState(load_state_payload) + onSaveResult({ok:false, errors:{_general: "Internal error: #{e.message.scrub('?')}"}})...; end`; (c) внутренний `dialog.execute_script` в catch-handler'е сам wrap'нут в `begin/rescue StandardError; nil; end` против double-fault на закрытом диалоге. `persist_and_finalize` помечен `private_class_method`.
**Действие:** design §4.3 (round 1); plan Step 8.2 — переписан `on_save` + новый `persist_and_finalize` helper + comment про raison d'être round-2 (round 2).

---

### [CRITICAL-3] `URI::File.build` не делает то, что утверждает план

> «На Ruby 3.2.3 `URI::File.build(path: "/tmp/a b.log")` raises `URI::InvalidComponentError`; Windows drive-letter paths тоже требуют special handling. Show Log может падать именно на тех кейсах, ради которых выбран этот API. Также `URI::File` появился в Ruby 2.7, и поведение варьируется между SketchUp 2024-era embedded Ruby builds.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 1 (design `§5.3`, commit `644d193`) + round 2 (plan Step 8.3, this commit).
**Ответ:** В дизайне `§5.3` указано: helper нормализует `\` → `/`, добавляет leading `/` для Windows drive-letter путей, применяет `URI::DEFAULT_PARSER.escape`, и собирает `"file://#{escaped}"` (без `URI::File.build`). В плане Step 8.3 имплементирован `self.file_uri_for(path)` private helper по дизайну + переписан `show_log` для использования helper'а. Добавлены три unit-теста в `test/test_application_show_log.rb`: spaces → `%20`, Windows path `C:\Users\foo bar\mcp.log` → `file:///C:/Users/foo%20bar/mcp.log`, non-ASCII (`/tmp/журнал.log`) → percent-encoded bytes. Task 8 Files header расширен: `test/test_application_show_log.rb` создаётся в этом шаге.
**Действие:** design §5.3 (round 1); plan Step 8.3 — переписан под `file_uri_for` + новый test файл; Task 8 Files header расширен (round 2).

---

### [CRITICAL-4] `build_profile.rb` всё ещё может остаться после failure (`File.write` вне `begin`)

> «`File.write(build_profile_path, ...)` выполняется до `begin/ensure`, а cleanup начинается только в `ensure`. Если `File.write` создаст/частично создаст файл и затем упадёт (disk full, perms), `ensure` не сработает — сохраняется тот самый hidden state, который iter-1 CRITICAL-6 закрыл для zip-фазы.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 10.2 переупорядочен: `build_profile_path` и `temp_dir` объявляются ДО `begin`, но сам `File.write(build_profile_path, ...)` перенесён ВНУТРЬ `begin` блока. `ensure` теперь покрывает три фазы: write build_profile, staging cp_r + cp, zip pack. Cleanup-блок остался прежним (`FileUtils.rm_rf(temp_dir)` + `FileUtils.rm_f(build_profile_path)`), но теперь reliably ловит partial-write failures.
**Действие:** plan Step 10.2 — File.write перенесён внутрь begin block + comment про iter-2 CRITICAL-4 (round 2).

---

### [CRITICAL-5] Strict grep сам себе противоречит (`SU_MCP_SERVER` literal в release.md)

> «release.md addition explicitly inserts `SU_MCP_SERVER` в двух местах, но Step 12.8 затем запрещает `SU_MCP_SERVER` в non-historical tracked files. Task 12 не может пройти как написан — `docs/release.md` не исключён из grep, значит strict check будет падать на текст, который сам план только что добавил.»

**Источник:** codex-executor (с QUESTION-1 как sub-aspect — см. REPEAT ниже).
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 12.6 — оба упоминания `SU_MCP_SERVER` literal заменены на descriptive phrase «the dead v0.1.0 listing under the prior `su_`-prefixed product id» (вариант: «that ran under the prior `su_`-prefixed product id»). Step 12.8 PATTERNS оставлен без изменений (`SU_MCP_SERVER` всё ещё в regex как catch для будущих ошибок) — но теперь grep over release.md не находит совпадений, потому что literal вычищен. Plan-internal упоминание `SU_MCP_SERVER` в Step 14.0 (внутренний intake-pre-check checklist) оставлено: `docs/superpowers/plans/*` исключён из grep, plan-self не парсится как release artifact.
**Действие:** plan Step 12.6 — два места `SU_MCP_SERVER` literal удалены (round 2). Step 12.8 PATTERNS и плановский Step 14.0 не тронуты.

---

### [CRITICAL-6] Files lists неполные при explicit-path commit policy

> «Files header перечисляет только подмножество затрагиваемых файлов; новые test/helper файлы (config_reset.rb, test_build_profile_fixture.rb, test_package_default_variant.rb, test_smoke_helpers.py) и Step 8.3 application.rb (логика, не rename) пропущены. Имплементор, следуя explicit-path policy буквально, не застейджит их.»

**Источник:** codex-executor + ccs-executor/albb-deepseek + ccs-executor/albb-kimi (triple consensus).
**Статус:** Автоисправлено — round 1.
**Ответ:** Files headers Task 4/8/9/10/13 расширены под пакет round-1 fixes (см. commit `644d193` body). Round 2 в рамках CRITICAL-3 plan-side также добавил `test/test_application_show_log.rb` в Task 8 Files header. Все остальные затрагиваемые файлы уже зафиксированы в headers.
**Действие:** plan Task 4/8/9/10/13 Files headers (round 1); plan Task 8 Files header дополнен `test_application_show_log.rb` (round 2).

---

### [CRITICAL-7] Step 4.3(f) противоречит Step 4.0 — два разных подхода к reset

> «Step 4.0 предписывает заменить ad-hoc resets shared helper-ом `ConfigReset.reset_all!`. Step 4.3(f) снова показывает inline `setup` с ручным `nil` для каждого поля. Имплементор не поймёт, что делать: использовать `ConfigReset.reset_all!` или дополнить ручной список. Это не numbering issue — два параграфа предписывают взаимоисключающие действия для одного и того же `setup`.»

**Источник:** codex-executor (CONCERN-2) + ccs-executor/albb-deepseek (CRITICAL-1) + ccs-executor/albb-kimi (CRITICAL-3) (consensus).
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 4.3(f) удалён целиком. На его месте оставлена краткая «metadata note» (italic-параграф) объясняющая решение: subsection (f) был замещён `ConfigReset.reset_all!` из Step 4.0, чтобы не плодить два рассинхронизирующихся reset call site'а. Verified: Step 4.0's `ConfigReset.reset_all!` body покрывает все шесть полей (host, port, log_level, eval_enabled, log_to_file, log_file_path).
**Действие:** plan Step 4.3(f) удалён + замещающий decision-note (round 2).

---

### [CRITICAL-8] Post-build верификация не проверяет поле `name`

> «Step 10.2 `Zip::File.open` блок проверяет `product_id` и `version`, но НЕ `name`. Reviewer rejected v0.1.0 именно из-за имени («SketchUp MCP Server» implies first-party). Если `name` регрессирует, ре-сабмит снова провалится, а post-build check молча пропустит.»

**Источник:** ccs-executor/albb-deepseek (CRITICAL-3 deepseek-side).
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 10.2 post-build verify расширен: добавлен `unless meta["name"] == "MCP Server for SketchUp"; raise "post-build: name mismatch ..."; end` блок. Финальный `puts` обновлён чтобы показывать `name=...` тоже. Это catches regression at .rbz-build time; для более раннего feedback см. QUESTION-3 — добавлен также static unit-test на `extension.json` (Step 4.7.a).
**Действие:** plan Step 10.2 — name field assertion + updated puts (round 2).

---

### [CRITICAL-9] `#peer_label` fallback silently изменён с `"unknown"` на `"<unknown>"`

> «Step 2.11.b говорит "Preserve the existing fallback return `"<unknown>"`". Но текущий код `client_state.rb:57` возвращает `"unknown"` (без angle brackets). Это НЕ preservation — это behavioural change. Дизайн §7 таблица тоже показывает `"<unknown>"` как "After" но "Before" должно быть `"unknown"`.»

**Источник:** ccs-executor/albb-deepseek (CRITICAL-4 deepseek-side).
**Статус:** Автоисправлено — round 1.
**Ответ:** Дизайн §7: Before-колонка для `ClientState#peer_label` исправлена на `"unknown"`, добавлены две строки про silent-rescue в `validation.rb` и `settings_dialog.rb`. План: replace_all `"<unknown>"` → `"unknown"`; Step 2.11.b переписан с явным акцентом «Preserve the existing literal "unknown" verbatim — DO NOT introduce angle brackets».
**Действие:** design §7 + plan Step 2.11.b + plan replace_all (round 1).

---

### [CONCERN-1] Оставшиеся silent-looking rescues могут снова привлечь reviewer-а

> «`helpers/validation.rb:57` содержит `Integer(v.to_s, 10) rescue nil`; `ui/settings_dialog.rb:126-127` silently swallows secondary `execute_script` failure. Они не эквивалентны скрытию production bugs, но reviewer уже отметил silent rescues.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 1.
**Ответ:** В дизайне `§7` добавлены две новые строки: (1) `helpers/validation.rb:57` — заменено на explicit `begin/rescue ArgumentError`; (2) `ui/settings_dialog.rb` secondary execute_script — minimum `Logger.log("DEBUG", "...")` вместо bare rescue.
**Действие:** design §7 (round 1).

---

### [CONCERN-2] `sed -i` не переносим на macOS (BSD sed)

> «План многократно использует GNU-style `sed -i` без backup suffix (Task 1.4, 1.6, Task 12.1, Task 12.7). На macOS/BSD sed это падает. Учитывая, что SketchUp dev часто на macOS, лучше заменить на `ruby -pi -e`/`perl -pi -e` или explicit GNU sed prerequisite.»

**Источник:** codex-executor + ccs-executor/albb-kimi.
**Статус:** Автоисправлено — round 2.
**Ответ:** В plan preamble (рядом с `Commit policy`) добавлена однострочная portability note: «sed -i' в Tasks 1/12 использует GNU syntax; на macOS BSD sed substitute `gsed` (`brew install gnu-sed`) или адаптируй к `sed -i.bak '...' file && rm -f file.bak`. План не branch'ит по платформе; pick one form per host при выполнении.» Sed-команды в самих Tasks 1/12 оставлены как есть — preamble decision документирует ожидание операционного выбора.
**Действие:** plan preamble — portability note (round 2).

---

### [CONCERN-3] Boolean prefs слишком доверяют persisted storage

> «`raw_eval.nil? ? nil : !!raw_eval` и `!!raw_l2f` превратят persisted string `"false"` в `true`. Settings пишет booleans, но prefs считаются untrusted. Надёжнее `coerce_bool_pref(value, default:)`, принимающий только `true`/`false`, иначе WARN + default/sentinel.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 4.3(c) — оба `!!` заменены на `coerce_bool_pref(key, value, default:)` private module function. Хелпер возвращает value только если это native `true`/`false`; иначе emit'ит one-shot WARN через `Logger.log("WARN", "config: non-boolean #{key} pref value #{value.inspect}; falling back to #{default.inspect}")` и возвращает default. Для `eval_enabled` сентинель-nil путь сохранён: `raw_eval.nil? ? nil : coerce_bool_pref(:eval_enabled, raw_eval, default: nil)` — `coerce_bool_pref` срабатывает только на corruption, не на «pref unset». Для `log_to_file` дефолт = `DEFAULTS[:log_to_file]` (false). Helper помечен `private_class_method`.
**Действие:** plan Step 4.3(c) + новая subsection (c.1) с definition + rationale (round 2).

---

### [CONCERN-4] `test_package_default_variant.rb` делает `Dir.chdir` без восстановления

> «Тест делает `Dir.chdir(File.expand_path("../mcp_for_sketchup", __dir__))`, но НЕ сохраняет/восстанавливает `Dir.pwd`. Minitest не изолирует working dir между тестами.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Отклонено (false positive).
**Ответ:** Step 10.6.a уже использует block form `Dir.chdir(...) do ... end`, который автоматически восстанавливает рабочую директорию при выходе из блока (включая исключения). Reviewer не дошёл до закрывающего `end` и принял за линейный chdir. Дополнительный `setup`/`teardown` не нужен.
**Действие:** Нет изменений.

---

### [CONCERN-5] `test_smoke_helpers.py` через `importlib` выполняет побочные эффекты `smoke_check.py`

> «`spec.loader.exec_module(_smoke)` выполняет ВЕСЬ `smoke_check.py` как модуль, включая `sys.path.insert(0, ...)` на строке 36. Это modifies `sys.path` глобально для всего test run.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Автоисправлено — round 2.
**Ответ:** Принят Variant A: `sys.path.insert(0, str(...))` в `examples/smoke_check.py` обёрнут в `if __name__ == "__main__":` guard. `from pathlib import Path` и helper-определения остаются на module scope. Под pytest editable install (`uv pip install -e .`) `from sketchup_mcp.* import ...` resolvable без sys.path манипуляции — guard является genuine no-op для test-пути. Step 13.4.a расширен большим раздел-комментарием объясняющим необходимость guard'а ДО добавления test'а.
**Действие:** plan Step 13.4.a — добавлено описание `__main__` guard'а в smoke_check.py + rationale; Task 13 Files header уже содержит "+ sys.path guard (iter-2 CONCERN-5)" (round 1 preempted Files header entry) (round 2).

---

### [CONCERN-6] Дизайн §7 — `ClientState#peer_label` колонка «Before» некорректна

> «Design:182 — в колонке "Before" написано `"<unknown>"`, но текущий код возвращает `"unknown"` (без angle brackets). Это та же проблема что CRITICAL-9, но на уровне дизайна.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Повтор (sub-aspect of CRITICAL-9).
**Ответ:** Решено вместе с CRITICAL-9 в round 1: design §7 Before-колонка исправлена на `"unknown"`.
**Действие:** См. CRITICAL-9.

---

### [CONCERN-7] `run_edge_op` error message изменится вместе с label

> «После Title-Case rename операций, error message станет `"Chamfer Edges: no edges could be cut..."`. Это поведенческое изменение в JSON-RPC error message, который Python-клиент может парсить. Smoke test не завязан на формат, но regex-парсеры могут сломаться.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Отклонено (false positive — explicitly accepted в плане).
**Ответ:** Plan Step 2.4 содержит explicit acceptance этой смены: error message ловится как «improved readability», а единственный клиент (Python `errors.py`) ловит JSON-RPC `code`, не parsing message text. Поведение задокументировано и принято — не «изменилось silently».
**Действие:** Нет изменений.

---

### [CONCERN-8] Smoke check eval skip: commit message описывает неверный механизм

> «Step 13.6 commit message говорит про "actionable plain-text disabled message" и "[-32010] format_error form". Но `_maybe_skip_eval` (Step 13.2) ловит `SketchUpError` с `e.code == EVAL_DISABLED_CODE`, а не текст. Commit message устарел относительно кода, который он коммитит.»

**Источник:** codex-executor (SUGGESTION-3) + ccs-executor/albb-deepseek (CONCERN-6) (consensus).
**Статус:** Автоисправлено — round 1.
**Ответ:** Step 13.6 commit message переписан под реальное поведение: «examples/smoke_check.py wraps eval_ruby calls in `_maybe_skip_eval`, which catches `SketchUpError(EVAL_DISABLED_CODE)` and tallies the skip rather than aborting».
**Действие:** plan Step 13.6 commit message rewrite (round 1).

---

### [CONCERN-9] `test_settings_dialog.rb` помечен «Modify», но шагов модификации нет

> «Task 8 Files header говорит «Modify: `test/test_settings_dialog.rb`». Однако в шагах Task 8 единственное упоминание — Step 8.4 "Verify existing test_settings_dialog still passes". Header вводит в заблуждение.»

**Источник:** ccs-executor/albb-kimi (CONCERN-2 + QUESTION-2).
**Статус:** Автоисправлено — round 1.
**Ответ:** Files entry заменён с «Modify» на «Verify (no code change): `test/test_settings_dialog.rb` — Step 8.4 runs the existing suite to catch regressions; not "Modify"». Это снимает противоречие — explicit-path commit policy не требует staging этого файла, и header честен про его роль.
**Действие:** plan Task 8 Files header annotation (round 1).

---

### [CONCERN-10] `test_log_to_file_failure_falls_back_silently` не проверяет DEBUG fallback-сообщение

> «Тест проверяет только "не кидает исключение". Design §5.2 обещает "one-shot DEBUG console line" при падении записи в файл. Тест не проверяет его наличие, что позволяет регрессию (например, забыть вызвать `_emit_console` в fallback).»

**Источник:** ccs-executor/albb-kimi (CONCERN-3 + SUGGESTION-2).
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 5.1 тест расширен: (a) `Config.log_level = "DEBUG"` save+restore через `ensure`; (b) `$stdout` redirected в `StringIO`; (c) после `Logger.log("WARN", "ok")` assert: `captured.string` содержит `[MCPforSU] [DEBUG] log file write failed`. Сохранён старый rescue-flunk на raise; DEBUG-assert добавлен после ensure. Comment объясняет почему simple «не raise» test был vacuously passing.
**Действие:** plan Step 5.1 — extended `test_log_to_file_failure_falls_back_silently` (round 2).

---

### [CONCERN-11] PATTERNS в Task 12.8 не ловит «SketchUp MCP Server» (capital U)

> «PATTERNS='su_mcp|SU_MCP|Sketchup MCP Server|SketchupMCP|SU_MCP_SERVER'. "SketchUp" с заглавным U отсутствует. Если где-то осталась форма "SketchUp MCP Server", grep её пропустит.»

**Источник:** ccs-executor/albb-kimi (CONCERN-4 + SUGGESTION-3).
**Статус:** Автоисправлено — round 1.
**Ответ:** Step 12.8 PATTERNS расширен: добавлен `SketchUp MCP Server` (capital U) рядом с уже-присутствующим `Sketchup MCP Server` (capital S). Grep теперь покрывает обе capitalization-варианта.
**Действие:** plan Step 12.8 PATTERNS (round 1).

---

### [CONCERN-12] Smoke check `eval_skipped` — неясный scope счётчика

> «Step 13.3 объявляет `eval_skipped = 0` "at the top of the run" и инкрементирует внутри обёрнутых eval-вызовов. Если `_maybe_skip_eval` вызывается во вложенной async-функции, Python требует `nonlocal eval_skipped`, иначе `UnboundLocalError`.»

**Источник:** ccs-executor/albb-kimi (CONCERN-5 + QUESTION-3).
**Статус:** Автоисправлено — round 2.
**Ответ:** Принят mutable-container pattern: `eval_skipped = [0]` (1-element list) вместо bare int; `eval_skipped[0] += 1` при skip; final print через `{eval_skipped[0]}`. Мутация list не требует `nonlocal` declaration, потому что переменная не rebind'ится — только мутирует объект. Add'ed prominent comment в плане объясняющий почему list, а не int + `nonlocal` (последнее silently fail'ит если забыть declaration).
**Действие:** plan Step 13.3 — mutable container pattern + rationale comment (round 2).

---

### [SUGGESTION-1] Verify `build_profile.rb` content inside built `.rbz`

> «Добавить package test, который открывает default-built `.rbz` и проверяет не только filename `*-warehouse.rbz`, но и `core/build_profile.rb` с `EVAL_ENABLED_BY_DEFAULT = false`.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 2.
**Ответ:** `test/test_package_default_variant.rb` расширен (Step 10.6.a): после `refute_empty files, ...` добавлен `Zip::File.open(files.first) do |zf| ... end` блок, открывающий produced `.rbz`, ищущий entry `mcp_for_sketchup/core/build_profile.rb`, и asserting (a) entry exists; (b) body contains `EVAL_ENABLED_BY_DEFAULT = false`; (c) body contains `VARIANT                 = "warehouse"`. Это catches regression в variant→eval-default wiring внутри `package.rb` (например, inverted EVAL_DEFAULT logic), который иначе silently shipped warehouse build с eval enabled. Test renamed на `test_default_variant_produces_warehouse_rbz_with_eval_disabled` чтобы reflect расширенный contract.
**Действие:** plan Step 10.6.a — extended test с Zip::File.open verification (round 2).

---

### [SUGGESTION-2] Non-inherited `const_defined?` в `eval_enabled?`

> «Для `Core.const_defined?` в `eval_enabled?` использовать non-inherited lookup: `Core.const_defined?(:BuildProfile, false)` и `Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT, false)`.»

**Источник:** codex-executor.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 4.3(e) `eval_enabled?` getter — оба `const_defined?` вызова получили `false` argument: `Core.const_defined?(:BuildProfile, false)` и `Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT, false)`. Добавлен inline comment объясняющий: «`const_defined?(:X, false)` skips inherited constants — без флага stray top-level `BuildProfile` от другого плагина в shared Ruby namespace мог бы маскировать наш intent.»
**Действие:** plan Step 4.3(e) — non-inherited const_defined? + comment (round 2).

---

### [SUGGESTION-3] `truthy?` nil-semantics comment

> «`truthy?(nil)` → `false`. На уровне UI это ок (dialog никогда не шлёт nil), но семантически "missing pref" значит "unset", не "false". Стоит документировать это различие в комментарии к `truthy?`.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 7.3 — `self.truthy?` получил расширенный комментарий: «nil normalises to `false` here because the dialog never sends nil. Семантически a missing pref means «unset», not «false» — that distinction matters at the Config layer (sentinel-nil → BuildProfile fallback) but not in this validator, which only sees fully-populated dialog payloads. Don't reuse this helper from Config code.» Это документирует layer-boundary для будущих читателей.
**Действие:** plan Step 7.3 — comment block перед `self.truthy?` (round 2).

---

### [SUGGESTION-4] `write_default(..., nil)` semantics comment в Step 14.7.7a

> «Вызов `Sketchup.write_default("MCPforSketchUp", "eval_enabled", nil)` — валидный API для удаления ключа? Стоит добавить краткий комментарий объясняющий semantics.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 14.7.7a — добавлен comment непосредственно перед `Sketchup.write_default(...)` вызовом: «`Sketchup.write_default(section, key, nil)` — это SketchUp API contract для *удаления* ключа из prefs section — НЕ "set the key's value to nil". После deletion next `Sketchup.read_default(section, key, default)` returns `default`, что триггерит BuildProfile fallback внутри `Config.eval_enabled?` (sentinel-nil → BuildProfile::EVAL_ENABLED_BY_DEFAULT).»
**Действие:** plan Step 14.7.7a — embedded Ruby comment (round 2).

---

### [SUGGESTION-5] `load` vs `require` comment в Step 4.5.a fixture

> «`load @tmp.path` вместо `require`. Это правильно (`load` всегда перезагружает файл, `require` кеширует по пути), но стоит явный комментарий о причине для будущих читателей.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 4.5.a — после `load @tmp.path` строки добавлен inline comment: «`load` (not `require`) because we re-define the same constant per setup; `require` would memoise the first definition and silently skip subsequent reload attempts (so later tests would observe stale BuildProfile bodies from earlier tests).»
**Действие:** plan Step 4.5.a — embedded Ruby comment (round 2).

---

### [SUGGESTION-6] `on_save` normal vs confirm path divergence

> «После Config.update! и dialog.execute_script("window.onSaveResult(...)"), диалог закрывается через dialog.close. Но состояние диалога НЕ обновляется через applyState после успешного save (в normal path). Confirm-путь вызывает applyState явно.»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Отклонено (intentional design).
**Ответ:** Разница объяснима: confirm-путь НЕ закрывает диалог (пользователь остаётся в диалоге после Yes/No), а normal path закрывает. Reviewer сам заметил это в финальном предложении («Это ок, но отличается...»). Round 2 CRITICAL-2 в любом случае объединил оба пути через `persist_and_finalize` helper, который посылает `applyState` в обоих случаях (теперь даже normal path делает applyState перед dialog.close — небольшой positive side-effect). Дополнительных изменений не требуется.
**Действие:** Нет изменений (отдельно). Сторонне покрыто CRITICAL-2 helper extraction.

---

### [QUESTION-1] Должен ли `docs/release.md` проходить strict legacy grep?

> «Сейчас план одновременно требует оба поведения: release.md содержит literal `SU_MCP_SERVER`, и Step 12.8 запрещает его в non-historical files. Что выбрать?»

**Источник:** codex-executor.
**Статус:** Повтор (sub-aspect of CRITICAL-5).
**Ответ:** Решено вместе с CRITICAL-5 в round 2: literal `SU_MCP_SERVER` вычищен из release.md, Step 12.8 grep остаётся strict как и было задумано.
**Действие:** См. CRITICAL-5.

---

### [QUESTION-2] Поведение `UI.messagebox` на macOS для двухфазного confirm flow

> «На macOS `UI.messagebox` показывает app-modal sheet. Вызов из `UI.start_timer(0, false)` должен работать. Но есть ли риск, что messagebox появится BEHIND других окон (аналогично Windows quirk)? Проверялось ли empirically?»

**Источник:** codex-executor + ccs-executor/albb-deepseek (consensus).
**Статус:** Автоисправлено — round 2.
**Ответ:** Step 14.7 manual acceptance test расширен новым subitem `11.` под macOS: «repeat steps 7a–9 на macOS и подтвердить (a) messagebox appears in front of SketchUp window; (b) fully modal до dismissal. Two-phase deferred flow должен make this OK, но SketchUp/macOS window stacking исторически unreliable для native dialogs из HtmlDialog callbacks — empirical verification is the only safe check.»
**Действие:** plan Step 14.7 — добавлен subitem 11 (round 2).

---

### [QUESTION-3] Static `product_id` + `name` check в CI вместо post-build only

> «Post-build verify в `package.rb` проверяет fields только при сборке. Если кто-то случайно изменит `extension.json` в коммите, это не будет поймано до момента сборки (Step 14.3). Стоит ли добавить статический test (например, в test/run_all.rb), который проверяет `extension.json`?»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Автоисправлено — round 2.
**Ответ:** Добавлен новый plan Step 4.7.a (после Step 4.7 commit): создаёт `test/test_extension_json.rb` с двумя asserts: `meta["product_id"] == "MCP_FOR_SKETCHUP"` и `meta["name"] == "MCP Server for SketchUp"`. Тест читает `mcp_for_sketchup/extension.json` через `JSON.parse(File.read(EXT_JSON))`, EXT_JSON = `File.expand_path("../mcp_for_sketchup/extension.json", __dir__)`. Файл также добавлен в Task 4 Files header в round 1. Step pinned commentary объясняет: catches regression при `ruby test/run_all.rb` time, до того как кто-то запустит `package.rb` (Step 10.2 post-build verify сработал бы только при .rbz pack time, гораздо позже).
**Действие:** plan Step 4.7.a — новый шаг + test/test_extension_json.rb (round 2). Task 4 Files header уже содержит запись (round 1).

---

### [QUESTION-4] Судьба `su_mcp_v0.1.0.rbz` в git history

> «После Task 1 rename, `git mv su_mcp mcp_for_sketchup` перемещает директорию. Старые `.rbz` файлы внутри `su_mcp/` (если есть) тоже переедут. Нужно ли явно упомянуть очистку?»

**Источник:** ccs-executor/albb-deepseek.
**Статус:** Отклонено (false positive — уже покрыто).
**Ответ:** `*.rbz` уже в `.gitignore:28`. Никаких `.rbz` файлов в git-tracked tree нет, поэтому `git mv` ничего не переместит. Step 10.7 + 10.8 в плане также включают cleanup test artifacts перед commit'ом. Reviewer не проверил .gitignore.
**Действие:** Нет изменений.

---

### [QUESTION-5] Task 8 `application.rb` organisation

> «`show_log` в `application.rb` (Step 8.3) изменяет core-логику (menu action), а не UI. Возможно, логичнее было бы поместить его в Task 5 (Logger). Какова интенция автора?»

**Источник:** ccs-executor/albb-kimi (QUESTION-1).
**Статус:** Отклонено (task-organization preference, не defect).
**Ответ:** `show_log` логически связан с settings flow (log_to_file toggle в Settings UI), поэтому Task 8 — appropriate грouping. Перемещение в Task 5 разорвало бы рассказ «pref toggle → menu behaviour change» на две задачи и потребовало бы reordering tests. Task ordering rationale в преамбуле явно принимает functional grouping over module-level grouping.
**Действие:** Нет изменений.

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` | Round 1 (commit `644d193`): §4.3 (timer-internal rescue + persist_and_finalize), §5.1 (preserve log_tool + DEBUG-gated first(3) backtrace), §5.3 (file_uri_for escape helper заменяет URI::File.build), §7 (peer_label «unknown» Before/After + 2 silent-rescue rows). Round 2: дизайн не тронут — все round-2 fixes plan-side. |
| `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` | Round 1: Task 4/8/9/10/13 Files headers; replace_all `"<unknown>"` → `"unknown"`; Step 2.11.b «preserve unknown verbatim»; Step 12.8 PATTERNS capital-U `SketchUp MCP Server`; Step 13.6 commit message → `SketchUpError(EVAL_DISABLED_CODE)` catch. Round 2: preamble portability note (sed BSD); Step 3.3 surgical Logger rewrite + test DEBUG-gate fix; Step 4.3 удалён (f) + added (c.1) `coerce_bool_pref` helper + `const_defined?(:X, false)`; Step 4.5.a `load` vs `require` comment; new Step 4.7.a + `test/test_extension_json.rb`; Step 5.1 DEBUG fallback assertion; Step 7.3 `truthy?` nil-semantics comment; Task 8 Files header добавлен `test_application_show_log.rb`; Step 8.2 `persist_and_finalize` helper + timer rescue; Step 8.3 `file_uri_for` helper + 3 unit-теста; Step 10.2 `File.write` внутрь `begin` + name field verify; Step 10.6.a build_profile content + VARIANT assertion; Step 12.6 убраны два `SU_MCP_SERVER` literal; Step 13.3 `eval_skipped = [0]` mutable container; Step 13.4.a `sys.path.insert` guard rationale; Step 14.7 macOS messagebox modality subitem 11; Step 14.7.7a `write_default(nil)` semantics comment. |
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md` | Новый файл (этот) — round-2 decisions log. |
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md` | Уже зафиксирован в commit `644d193` (round 1). |

## Статистика

- Всего замечаний: 32 (9 CRITICAL + 12 CONCERN + 6 SUGGESTION + 5 QUESTION).
- Автоисправлено round-1 (commit `644d193`): 13 fixes покрывающие CRITICAL-1/2/3 design side, CRITICAL-6 (Files headers — 5 tasks), CRITICAL-9 (design + plan), CONCERN-1, CONCERN-8, CONCERN-9, CONCERN-11.
- Автоисправлено round-2 (этот commit): 19 numbered fixes покрывающие CRITICAL-1/2/3 plan side, CRITICAL-4, CRITICAL-5, CRITICAL-7, CRITICAL-8, CONCERN-2, CONCERN-3, CONCERN-5, CONCERN-10, CONCERN-12, SUGGESTION-1, SUGGESTION-2, SUGGESTION-3, SUGGESTION-4, SUGGESTION-5, QUESTION-2, QUESTION-3.
- Всего AUTO: 25 distinct issues (round 1 + round 2 без double-count тех, что имели design+plan стороны).
- Обсуждено с пользователем: 0 (round-1 классификация = 25 AUTO + 0 DISPUTED + 5 DISMISSED + 2 REPEAT; не было disputed item'ов, требующих диалога).
- Отклонено (false positive / intentional / already-covered): 5 (CONCERN-4 Dir.chdir block form already used; CONCERN-7 run_edge_op message explicitly accepted в Step 2.4; SUGGESTION-6 on_save divergence intentional; QUESTION-4 *.rbz already in .gitignore; QUESTION-5 task organization preference).
- Повторов (autoanswered с reference): 2 (CONCERN-6 = sub-aspect CRITICAL-9; QUESTION-1 = sub-aspect CRITICAL-5).
- Пользователь сказал «стоп»: Нет.
- Агенты: codex-executor (gpt-5.5 xhigh) + ccs-executor/albb-deepseek (DeepSeek-V4 Pro 1M) + ccs-executor/albb-kimi (recovered после iter-1 stall). albb-glm skipped per user preference; glm + albb-qwen failed.

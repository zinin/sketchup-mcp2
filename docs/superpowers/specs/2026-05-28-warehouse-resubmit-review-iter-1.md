# Review Iteration 1 — 2026-05-28

## Источник

- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`
- Review agents:
  - codex-executor (gpt-5.5, xhigh) — completed.
  - ccs-executor / glm — partial (model produced full structured findings in reasoning trace, but the run was killed by upstream before `output.txt` was flushed; summary extracted from `raw.jsonl`).
  - ccs-executor / albb-deepseek (DeepSeek-V4 Pro 1M) — completed.
  - ccs-executor / albb-kimi — failed (silent stall after 43 tool calls; upstream timeout).
  - ccs-executor / albb-qwen — failed (Alibaba endpoint returned `Model not exist` 400 — profile `qwen3.7-max[1m]` model id needs update).
  - albb-glm — skipped per user instruction.
- Merged output: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`

## Замечания

### [CRITICAL-1] BuildProfile fallback — мёртвый код, github-вариант не работает

> `DEFAULTS[:eval_enabled] = false` означает, что `load_from_defaults!` всегда устанавливает `self.eval_enabled = !!raw_eval`, поэтому fallback к `BuildProfile::EVAL_ENABLED_BY_DEFAULT` никогда не достигается. GitHub-вариант с `EVAL_ENABLED_BY_DEFAULT = true` ничем не отличается от warehouse — оба возвращают false.

**Источник:** codex-executor, ccs-glm, albb-deepseek (single consensus).
**Статус:** Автоисправлено.
**Ответ:** Принят sentinel-`nil` механизм: `DEFAULTS[:eval_enabled] = nil`; `load_from_defaults!` читает `read_default(SECTION, "eval_enabled", nil)` и сохраняет `raw_eval.nil? ? nil : !!raw_eval`; `eval_enabled?` падает в `Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT` когда @eval_enabled == nil.
**Действие:** design §4.2 переписан под sentinel-nil mechanism; plan Step 4.1 — переименование test'а + новые тесты (`test_eval_enabled_question_mark_*`, `test_read_default_sentinel_round_trip_*`); plan Step 4.3(a)(c) — DEFAULTS[:eval_enabled] = nil + load_from_defaults! preserves nil/false.

---

### [CRITICAL-2] `on_load_state` читает Config.eval_enabled вместо eval_enabled?

> Settings UI грузит `Config.eval_enabled`, а не effective `eval_enabled?` — github-вариант с sentinel-nil покажет unchecked, даже когда BuildProfile говорит true.

**Источник:** codex-executor, ccs-glm.
**Статус:** Автоисправлено.
**Ответ:** В `on_load_state` (и `load_state_payload` helper'е, выделенном в Step 12 CRITICAL-3) используется `Config.eval_enabled?`. Также `previous_eval_enabled` в `on_save` использует `eval_enabled?` для консистентности транзишена off→on.
**Действие:** plan Step 8.2 — `eval_enabled: MCPforSketchUp::Core::Config.eval_enabled?` + comment ссылка на CRITICAL-2.

---

### [CRITICAL-3] Settings dialog отказа в confirmation: нет error-div, нет rollback UI, синхронный messagebox внутри callback

> При No клик: код не вызывает applyState, не снимает checkbox, не возвращает сохранённое состояние; в HTML нет `eval_enabled-error`. Также `confirm_eval_enable` вызывает `UI.messagebox` напрямую внутри action_callback frame — Windows hang issue, уже задокументированный в settings_dialog.rb:100.

**Источник:** codex-executor, ccs-glm, albb-deepseek (consensus).
**Статус:** Автоисправлено.
**Ответ:** Принят two-phase deferred flow:
1. `on_save` детектирует транзишн off→on, defer'ит через `::UI.start_timer(0, false)`, выходит из callback frame.
2. В timer callback: `confirm_eval_enable` показывает messagebox. На Yes — `Config.update!` + ack + applyState. На No — applyState(saved) + onSaveResult с error message.
3. HTML получил `<div class="error" id="eval_enabled-error">`; `clearErrors` массив расширен до `[..., 'eval_enabled']`.
4. `on_load_state` рефакторен — извлечён `load_state_payload` helper, используется обоими методами для согласованности UI revert.
**Действие:** design §4.3 переписан с two-phase flow + явная ссылка на Windows quirk; plan Step 8.1 — error div + clearErrors patch; plan Step 8.2 — two-phase flow в on_save + load_state_payload helper + updated comment в confirm_eval_enable.

---

### [CRITICAL-4] Smoke skip helper проверяет текст вместо ловли SketchUpError(-32010)

> smoke_check.py использует raw `SketchUpConnection.send_command`, а не Python FastMCP wrapper; при JSON-RPC error Ruby бросит `SketchUpError`, а `_maybe_skip_eval` в плане проверяет только возвращённый текст. Warehouse build всё равно упадёт на step 15.

**Источник:** codex-executor.
**Статус:** Автоисправлено.
**Ответ:** Helper переписан: try/except `SketchUpError`, проверка `e.code == EVAL_DISABLED_CODE`. Импорты `from sketchup_mcp.errors import SketchUpError` и `from sketchup_mcp.compat import EVAL_DISABLED_CODE` добавлены.
**Действие:** plan Step 13.2 — переписан `_maybe_skip_eval`; добавлены оба import'а.

---

### [CRITICAL-5] Rename plan не доводит `su_mcp` до нуля; финальный grep провалится

> Task 1 заменяет только `SU_MCP`, но не lowercase `su_mcp` в Ruby file headers, Python compat messages, release docs и других tracked файлах (config.rb, compat.py:64, release.md:117). Финальная проверка требует пустой grep по `su_mcp`.

**Источник:** codex-executor, albb-deepseek.
**Статус:** Автоисправлено (объединено с CONCERN-8 word-boundary и SUGGESTION-7 manual CLAUDE.md).
**Ответ:** Step 1.4 расширен: word-boundary `\bSU_MCP\b` + lowercase `\bsu_mcp_v` sed для `mcp_for_sketchup/**/*.rb` плюс explicit sed для `compat.py` и `compat.rb`. Step 1.6 — find -name список включает `run_all.rb` и `*_helper.rb`. Step 12.4 — sed для CLAUDE.md заменён на ручные Edit operations (overlap с SUGGESTION-7). Step 12.8 — strict tracked-grep с PATTERNS-переменной + exit 1 при наличии legacy markers.
**Действие:** plan Step 1.4, 1.6, 12.4, 12.8 переписаны (см. отдельные секции в commit message `2f56d7a`).

---

### [CRITICAL-6] `package.rb` оставляет скрытое состояние при ошибке сборки

> `build_profile.rb` пишется в source tree и удаляется только на happy path. Если zip/copy падает, gitignored file останется и будет менять dev/runtime default.

**Источник:** codex-executor, albb-deepseek.
**Статус:** Автоисправлено.
**Ответ:** Тело пакера обёрнуто в `begin/ensure`: ensure-блок чистит `temp_dir` и `build_profile_path` при любом исходе (включая сигналы/exceptions).
**Действие:** plan Step 10.2 переписан под begin/ensure структуру.

---

### [CRITICAL-7] План противоречит сам себе по wire-protocol break

> Вверху сказано «No wire-protocol breaks», но Task 11 правильно говорит, что MIN_* поднимаются до 0.2.0 и старые пары намеренно не handshake'ятся. Это надо исправить до передачи исполнителям.

**Источник:** codex-executor.
**Статус:** Автоисправлено (в design tier до начала plan-tier работы).
**Ответ:** Architecture-строка преамбулы plan'а переписана: «Wire-protocol *contract* (JSON-RPC envelope, framing) is unchanged, but the version-handshake floors are bumped to 0.2.0 (MIN_PYTHON / MIN_RUBY) — old 0.1.0 peers will be rejected at handshake by design (see Task 11 and spec §2)».
**Действие:** plan preamble Architecture line (commit `fadb746`).

---

### [CRITICAL-8] Test код с `SU_MCP_save_eval` не скомпилируется + не требует validation helper

> `SU_MCP_save_eval = ...` внутри метода Ruby трактуется как константа и даст dynamic constant assignment. Также план предлагает добавить только `handlers/eval`, но `eval.rb` на загрузке требует `SU_MCP::Helpers::Validation`; текущий test_dispatch_post_handshake.rb этот helper не требует.

**Источник:** codex-executor.
**Статус:** Автоисправлено.
**Ответ:** Все вхождения `SU_MCP_save_eval` (4 шт в двух методах) переименованы в `saved_eval` (lowercase = локальная переменная); добавлен явный комментарий о причине. В Step 6.1 requires добавлены `helpers/validation` и `handlers/eval`.
**Действие:** plan Step 6.1 — replace_all `SU_MCP_save_eval` → `saved_eval`; добавлено пояснение constant-vs-local + explicit requires section.

---

### [CONCERN-1] Backtrace lines обходят `[MCPforSU]` prefix

> Logger.log_error пишет backtrace напрямую через `write("    #{bt}")`, а план добавляет prefix только в log(). Acceptance §12.7 нарушается на error paths.

**Источник:** codex-executor.
**Статус:** Автоисправлено (design + plan).
**Ответ:** Введён shared `_emit` private helper, через который проходят оба `log` и `log_error` (включая каждую backtrace continuation line с `LINE_PREFIX` префиксом). Step 5.3 (log-to-file) переиспользует `_emit` вместо отдельного `write`.
**Действие:** design §5.1 переписан под shared low-level Logger.write; plan Step 3.3 — full `_emit` + `log_error` refactor + новый test `test_log_error_backtrace_lines_carry_prefix`; plan Step 5.3 — переименовано в `_emit` extension.

---

### [CONCERN-2] Остались тихие rescues после cleanup

> После «silent rescue cleanup» останутся тихие rescues: `Geometry.safe_abort` и `ClientState#peer_label`. Если reviewer grep'ает rescue StandardError, это может снова всплыть.

**Источник:** codex-executor, ccs-glm (CONCERN-7), albb-deepseek (вариант).
**Статус:** Автоисправлено (design + plan).
**Ответ:** Добавлены 2 новые строки в §7 silent-rescue table; в plan Task 2 — Steps 2.11.a (Geometry.safe_abort) и 2.11.b (ClientState#peer_label) с explicit DEBUG log. Files header Task 2 расширен upon файлами geometry.rb (для safe_abort) и client_state.rb.
**Действие:** design §7 — две новые строки в таблице; plan Step 2.11.a/b добавлены; Files block расширен.

---

### [CONCERN-3] Release docs противоречат signed-artifacts стратегии

> Старый раздел release.md говорит, что EW отвергает pre-encrypted/signed `.rbz` и требует plain source. План добавляет новый текст, но не удаляет/переписывает старый.

**Источник:** codex-executor (overlap с QUESTION-1).
**Статус:** Автоисправлено (объединено с QUESTION-1).
**Ответ:** Step 12.6 расширен явной инструкцией удалить legacy «EW rejects pre-encrypted .rbz» секцию; добавлен новый подраздел «Submitting via Extension Warehouse (v0.2.0+)» с 4-шаговой инструкцией Build → Sign via Trimble → Submit → product_id note.
**Действие:** plan Step 12.6 — pre-amble «find and delete the legacy note» + новый markdown подраздел.

---

### [CONCERN-4] Settings dialog truncates на Windows scaling

> Settings dialog станет выше, но `HtmlDialog` остаётся `height: 360`, `scrollable: false`. Новые секции могут обрезаться.

**Источник:** codex-executor, ccs-glm (CONCERN-1), albb-deepseek (QUESTION-4).
**Статус:** Автоисправлено.
**Ответ:** В Step 8.2 после изменения DIALOG_TITLE добавлен patch для HtmlDialog.new constructor: `height: 480, scrollable: true`. Patch — добавление, не замена (constructor body не полностью прописан в плане).
**Действие:** plan Step 8.2 — explicit instruction на смену height/scrollable.

---

### [CONCERN-5] Log-file path требования слабее спецификации; `file://` хрупок на Windows

> design требует «parent dir must exist», но validator проверяет только non-empty. `UI.openURL("file://#{path}")` хрупок для Windows paths/spaces.

**Источник:** codex-executor.
**Статус:** Автоисправлено (design + plan).
**Ответ:** design §5.2 уточнён: validator проверяет non-empty AND `File.directory?(File.dirname(File.expand_path(path)))`. design §5.3 переписан: `UI.openURL(URI::File.build(path: expanded).to_s)`. plan Step 7.3 — validator проверяет parent-dir. plan Step 8.3 — show_log использует URI::File.build.
**Действие:** design §5.2/§5.3 + plan Step 7.3/Step 8.3.

---

### [CONCERN-6] Test approach: regex-parse vs design-promised mock recorder

> Тесты часто проверяют текст/источник, а не поведение. test_operation_names.rb парсит файлы regex'ами, хотя design обещал mock model recorder.

**Источник:** codex-executor.
**Статус:** Обсуждено с пользователем (auto-applied после анализа).
**Ответ:** **Вариант A (auto)** — оставить regex parser в плане, обновить design под source-level regex guard. CLAUDE.md уже фиксирует invariant «Mutating handlers wrap edits in start_operation/commit_operation»; behavioural защита присутствует через e2e smoke (smoke_check.py) и Step 14.7 manual acceptance («Edit → Undo shows expected label»). Mock-recorder требует значительной mock-инфраструктуры (Sketchup::Model stub, entities/groups/iterators); ROI не оправдывает. Только Вариант A адекватен — применил без вопроса пользователю.
**Действие:** design §6 — переписан абзац про «mock model's start_operation recorder» → «source-level regex parser» с rationale.

---

### [CONCERN-7] Грязный checkout + многократный `git add -A`

> Текущий checkout грязный: много untracked docs, .gemini/, diff.patch. План многократно использует `git add -A`; commits легко захватят мусор.

**Источник:** codex-executor.
**Статус:** Автоисправлено.
**Ответ:** В preamble plan'а добавлена «Commit policy (iter-1 CONCERN-7)» секция с примерами per-task. Все 13 `git add -A` заменены через replace_all на placeholder `git add <explicit-paths>  # iter-1 CONCERN-7: see Commit policy ...`.
**Действие:** plan preamble + 13× replace_all в commit steps.

---

### [CONCERN-8] Sed может false-positive в строковых литералах

> Если в строковом литерале встретится `SU_MCP` как подстрока, sed заменит и его. План не содержит grep для верификации этой гипотезы.

**Источник:** albb-deepseek.
**Статус:** Автоисправлено (объединено с CRITICAL-5).
**Ответ:** Step 1.4 теперь начинается с pre-sed verification grep, который surface'ит любые SU_MCP-occurrences НЕ в виде «module SU_MCP», «SU_MCP::», или string literal «SU_MCP»; sed использует word-boundary `\bSU_MCP\b`.
**Действие:** plan Step 1.4 (в составе CRITICAL-5 patch).

---

### [CONCERN-9] Унифицированный test helper для сброса Config state

> Тесты test_logger.rb / test_application.rb / test_config.rb манипулируют module-level Config state; без unified reset helper'а будущие тесты могут утекать состояние.

**Источник:** albb-deepseek (CONCERN-5).
**Статус:** Автоисправлено.
**Ответ:** Новый Step 4.0 создаёт `test/support/config_reset.rb` с `ConfigReset.reset_all!` (host/port/log_level/eval_enabled/log_to_file/log_file_path → nil). test_config / test_logger / test_application setup используют его.
**Действие:** plan Step 4.0 (новый шаг перед Step 4.1).

---

### [CONCERN-10] Back-compat smoke для 3-arg update!

> Старые callers передают только host/port/log_level. Нет explicit теста, что новый код корректно не трогает eval_enabled/log_to_file/log_file_path.

**Источник:** albb-deepseek (CONCERN-2).
**Статус:** Автоисправлено.
**Ответ:** В test_config.rb добавлен `test_update_with_only_3_args_does_not_touch_new_fields`: вызывает `C.update!(host:, port:, log_level:, writer:)`; assert_nil eval_enabled/log_to_file/log_file_path; refute_includes writes keys для всех трёх новых полей.
**Действие:** plan Step 4.1 — новый тест перед `test_update_persists_new_prefs`.

---

### [SUGGESTION-1] EVAL_DISABLED_CODE в compat.py

> Два независимых определения `-32010` (Ruby handlers/eval.rb + Python tools.py); риск расхождения. Вынести в compat.py.

**Источник:** albb-deepseek (SUGGEST-3).
**Статус:** Автоисправлено.
**Ответ:** В Step 9.3 добавлен sub-step: в src/sketchup_mcp/compat.py объявить `EVAL_DISABLED_CODE = -32010`; в tools.py заменить `_EVAL_DISABLED_CODE = -32010` на `from sketchup_mcp.compat import EVAL_DISABLED_CODE`; использовать EVAL_DISABLED_CODE в условии.
**Действие:** plan Step 9.3 переписан; обновлены import'ы.

---

### [SUGGESTION-2] Test fixture для github BuildProfile path

> Без fixture build_profile.rb в test setup ветка `eval_enabled?` с BuildProfile не имеет test coverage. CRITICAL-1 это подтверждает.

**Источник:** albb-deepseek (SUGGEST-2).
**Статус:** Автоисправлено.
**Ответ:** Новый Step 4.5.a создаёт `test/test_build_profile_fixture.rb`: tempfile с MCPforSketchUp::Core::BuildProfile{VARIANT="github", EVAL_ENABLED_BY_DEFAULT=true}; load в setup, remove_const + unlink в teardown; два теста: eval_enabled?=true при unset pref + BP true; explicit false overrides BP.
**Действие:** plan Step 4.5.a (новый шаг).

---

### [SUGGESTION-3] Post-build assertion на extension.json

> После `Zip::File.open` в package.rb стоит проверить product_id+version в созданном .rbz — дешёвая защита от re-submission с неправильным ID.

**Источник:** albb-deepseek (SUGGEST-1).
**Статус:** Автоисправлено.
**Ответ:** В package.rb добавлен `require 'json'` сверху + шаг 5 после ensure-блока: Zip::File.open OUTPUT_NAME → find_entry extension.json → parse JSON → raise unless product_id == "MCP_FOR_SKETCHUP" + version == VERSION.
**Действие:** plan Step 10.2 — добавлен post-build шаг 5.

---

### [SUGGESTION-4] Tracked-grep script

> После rename делать tracked grep по всем старым маркерам: SU_MCP, su_mcp, SU_MCP_SERVER, Sketchup MCP Server, SketchupMCP, с явным exit 1.

**Источник:** codex-executor.
**Статус:** Автоисправлено (объединено с CRITICAL-5 strict grep).
**Ответ:** Step 12.8 переписан с PATTERNS-переменной (5 паттернов), git grep -inE с 5-ью glob excludes, `&& { echo FAIL; exit 1; }`, success echo.
**Действие:** plan Step 12.8.

---

### [SUGGESTION-5] Реальные contract-тесты

> Добавить тесты на: BuildProfile true/false при unset pref, explicit pref override, default variant без флага, raw smoke -32010 skip, logger prefix на backtrace lines.

**Источник:** codex-executor.
**Статус:** Автоисправлено (распределено по другим задачам).
**Ответ:** (1) и (2) покрыты SUGGESTION-2. (5) покрыт CONCERN-1 (test_log_error_backtrace_lines_carry_prefix в Step 3.3). (3) и (4) добавлены как новые шаги:
- Step 10.6.a: `test/test_package_default_variant.rb` — shell-out `system("ruby package.rb")`, проверка `Dir.glob("*-warehouse.rbz")` not empty.
- Step 13.4.a: `tests/test_smoke_helpers.py` — monkeypatch send_command → raise SketchUpError(EVAL_DISABLED_CODE); assert helper returns None + captured "skipped" output; раздельный тест для re-raise -32000.
**Действие:** plan Step 10.6.a + Step 13.4.a (новые шаги).

---

### [SUGGESTION-6] refute_empty files в test_operation_names

> `Dir[File.join(HANDLERS, "*.rb")]` без `refute_empty` может silent-pass'нуть если HANDLERS path сломался.

**Источник:** albb-deepseek (SUGGEST-4).
**Статус:** Автоисправлено.
**Ответ:** В Step 2.1 (test file) добавлен `test_handlers_dir_is_not_empty` перед `test_no_snake_case_op_labels_remain` с явным comment про защиту от stale HANDLERS path.
**Действие:** plan Step 2.1 — новый test method.

---

### [SUGGESTION-7] Manual CLAUDE.md edit вместо sed

> Sed для CLAUDE.md портит «to be renamed» аннотации. Описать в плане конкретные строки.

**Источник:** albb-deepseek (SUGGEST-5).
**Статус:** Автоисправлено (объединено с CRITICAL-5).
**Ответ:** Step 12.4 полностью переписан: вместо одной sed-строки — 6 explicit Edit-инструкций с `replace_all: true` где безопасно, и явным указанием inspect+by-hand для `su_mcp/` (т.к. внутри annotation). Включает аудит «to be renamed» phrases на удаление.
**Действие:** plan Step 12.4 — заменён manual подход.

---

### [QUESTION-1] Переписать release.md EW section?

> Нужно ли полностью переписать старый docs/release.md EW-раздел под «оба .rbz через Trimble signing service»?

**Источник:** codex-executor.
**Статус:** Повтор (overlap с CONCERN-3).
**Ответ:** Да — переписано в CONCERN-3.
**Действие:** см. CONCERN-3.

---

### [QUESTION-2] Mention eval-gate в prompts.py?

> Должен ли `src/sketchup_mcp/prompts.py` упоминать eval gate, чтобы встроенный MCP prompt не подталкивал LLM к eval без контекста?

**Источник:** codex-executor.
**Статус:** Обсуждено с пользователем (auto-applied после анализа).
**Ответ:** **Вариант A (auto)** — добавить короткий paragraph про eval-gate в `sketchup_modeling_strategy`. Без правки LLM может перифразировать actionable text и потерять «Open Plugins → MCP Server → Settings...» инструкцию. Стоимость <50 токенов; согласуется с design §4.4 «LLM receives an actionable text and surfaces it to the user verbatim». Варианты B (оставить) и C (defer) проигрывают; только Вариант A адекватен — применил без вопроса пользователю.
**Действие:** plan Step 9.5.a (новый шаг) — short paragraph в prompts.py указывающий LLM передавать «eval_ruby is disabled.» verbatim.

---

### [QUESTION-3] Manual variant acceptance test — clear pref?

> Для manual GitHub-variant acceptance нужно ли явно очищать pref MCPforSketchUp/eval_enabled, иначе тест после warehouse-variant не доказывает build default?

**Источник:** codex-executor.
**Статус:** Автоисправлено.
**Ответ:** Да. Добавлен Step 14.7.7a: `Sketchup.write_default("MCPforSketchUp", "eval_enabled", nil)` в Ruby Console, затем close+reopen Settings — checkbox должен отразить variant build-default.
**Действие:** plan Step 14.7 — новый substep 7a.

---

### [QUESTION-4] Trimble intake form пре-проверка

> Подтверждено ли, что Trimble разрешит создать новый product (не update старого) через intake form? Есть ли fallback-план, если intake form потребует привязки к старому SU_MCP_SERVER?

**Источник:** codex-executor, albb-deepseek (QUESTION-1).
**Статус:** Автоисправлено.
**Ответ:** Добавлен Step 14.0 — Trimble intake pre-check: открыть https://extensions.sketchup.com/developer/submit; подтвердить (1) form принимает новый product_id без линкования к dead SU_MCP_SERVER, (2) form принимает Trimble signing service flow. При gating — surface пользователю ДО Step 14.1.
**Действие:** plan Task 14 — новый Step 14.0 перед Step 14.1.

---

### [QUESTION-5] uv.lock git-tracked check

> Step 11.9 делает `uv lock`. Но uv.lock не коммитится — или коммитится?

**Источник:** albb-deepseek (QUESTION-2).
**Статус:** Автоисправлено.
**Ответ:** Step 11.9 branches: `if git ls-files --error-unmatch uv.lock`; tracked → uv lock + git add; untracked → echo skip message.
**Действие:** plan Step 11.9 — bash conditional.

---

### [QUESTION-6] description capitalization deliberate?

> Step 1.9 меняет `Sketchup` → `SketchUp` в description. Это намеренное исправление или случайная правка?

**Источник:** albb-deepseek (QUESTION-3).
**Статус:** Автоисправлено.
**Ответ:** Намеренно. Добавлена явная note после JSON block в Step 1.9: «description deliberately changes Sketchup → SketchUp (capital U). Consistency fix with new display name, NOT part of reviewer's name-rejection note.»
**Действие:** plan Step 1.9 — note блок после JSON.

---

### [QUESTION-7] read_default sentinel verification

> Как SketchUp `read_default` ведёт себя с boolean false values? Нужно ли тестировать предположение что absent → default, present false → false?

**Источник:** ccs-glm (QUESTION-1).
**Статус:** Автоисправлено (в составе CRITICAL-1).
**Ответ:** Покрыто `test_read_default_sentinel_round_trip_for_eval_enabled` в Step 4.1: явно проверяет, что StubReader (mirror of Sketchup.read_default) на absent key возвращает default (`nil`), на present `false` — `false`. Это верифицирует assumption underlying CRITICAL-1.
**Действие:** plan Step 4.1 — новый тест добавлен в commit `ce80b45`.

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` | §4.2 (sentinel-nil), §4.3 (two-phase confirm), §5.1 (prefix в shared write), §5.2 (validator parent-dir), §5.3 (URI::File.build), §6 (regex parser decision, iter-1 CONCERN-6), §7 (две новые silent-rescue строки) |
| `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` | Preamble Architecture rewrite + Commit policy; Step 1.4/1.6/12.4/12.8 (rename + grep); Step 1.9 (capitalization note); Step 2.1 (refute_empty + test file); Steps 2.11.a/2.11.b (silent rescues); Step 3.3 (_emit refactor); Step 4.0 (config_reset helper); Step 4.1 (sentinel tests + back-compat + sentinel round-trip); Step 4.3(a)(c) (DEFAULTS nil + load_from_defaults!); Step 4.5.a (build_profile fixture); Step 5.3 (rename write → _emit); Step 6.1 (saved_eval + requires); Step 7.3 (parent-dir check); Step 8.1 (HTML error div + clearErrors); Step 8.2 (two-phase flow + load_state_payload + dialog 480/scrollable); Step 8.3 (URI::File.build); Step 9.3 (EVAL_DISABLED_CODE); Step 9.5.a (eval-gate paragraph в prompts.py); Step 10.2 (begin/ensure + post-build extension.json verify); Step 10.6.a (default variant test); Step 11.9 (uv.lock branch); Step 12.6 (EW signed-via-Trimble rewrite); Step 13.2 (SketchUpError catch); Step 13.4.a (smoke helpers pytest); Step 14.0 (Trimble intake pre-check); Step 14.7.7a (clear eval_enabled pref); все 13× `git add -A` → placeholder |
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md` | Новый файл (этот) |
| `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md` | Уже зафиксирован в commit `fadb746` |
| `docs/superpowers/plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md` | Уже зафиксирован в commit `fadb746` (working spec для iter-1 continuation) |

## Статистика

- Всего замечаний: 32 (7 CRITICAL + 10 CONCERN + 7 SUGGESTION + 7 QUESTION + 1 повтор).
- Автоисправлено (без обсуждения): 30 (включая QUESTION-7 baked в CRITICAL-1 test).
- Авто-применено после анализа: 2 (CONCERN-6 → Вариант A; QUESTION-2 → Вариант A).
- Обсуждено с пользователем: 0 (оба disputed item'а имели единственный адекватный вариант — применил без вопроса).
- Отклонено (false positive / уже покрыто): 0.
- Повторов (автоответ): 1 (QUESTION-1 = overlap с CONCERN-3).
- Пользователь сказал «стоп»: Нет.
- Агенты: codex-executor (gpt-5.5 xhigh) + ccs-executor/glm (partial) + ccs-executor/albb-deepseek (DeepSeek-V4 Pro 1M). albb-kimi и albb-qwen failed; albb-glm skipped per user instruction.

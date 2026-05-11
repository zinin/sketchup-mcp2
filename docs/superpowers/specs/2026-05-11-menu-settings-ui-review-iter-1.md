# Review Iteration 1 — 2026-05-11

## Источник

- Design: `docs/superpowers/specs/2026-05-11-menu-settings-ui-design.md`
- Plan: `docs/superpowers/plans/2026-05-11-menu-settings-ui.md`
- Review agents: gemini-executor, ccs-executor (glm), ollama-executor (kimi), ollama-executor (deepseek). codex-executor — **FAILED** (security policy blocks `--dangerously-bypass-approvals-and-sandbox` in auto mode). ollama-executor (minimax) — **PENDING**, will be processed separately.
- Merged output: `docs/superpowers/specs/2026-05-11-menu-settings-ui-review-merged-iter-1.md`

## Замечания

### [CRITICAL-1] Неатомарность `Config.update!`

> Все 4 ревьюера (gemini, ccs-glm, ollama-kimi, ollama-deepseek): runtime мутируется после трёх `write_default`. Если упадёт 2-й/3-й — prefs частично записаны, runtime нетронут.

**Источник:** gemini, ccs-glm, ollama-kimi, ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Поменян порядок — runtime first, потом persistence. Любое падение write_default оставляет текущую сессию консистентной; prefs могут разойтись с runtime, но UI re-loads показывает реальное состояние из prefs.
**Действие:** Design §5.1 + Plan Task 1 Step 3 — swap order. Doc-comment в коде. Risks-таблица §8 обновлена ("partial persistence acceptable risk").

### [CRITICAL-2] Устаревший UI диалога после успешного Save

> 4 ревьюера: `applyState` вызывается только при DOM ready. После Save статус-блок не обновляется.

**Источник:** gemini, ccs-glm, ollama-kimi, ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** После `onSaveResult({ok:true})` вызывать `on_load_state(dialog)` — обновляет форму + status banner + "saved differs" hint. После restart timer (если user сказал Yes) тоже re-load для отражения нового running_config.
**Действие:** Design §5.5 (Save flow rewritten). Plan Task 5 (Dialog) — добавлен явный вызов on_load_state в on_save flow + после restart.

### [CRITICAL-3] `UI.messagebox` под Windows блокирует UI

> gemini: messagebox внутри action_callback на Windows может провалиться под главное окно, заморозить SketchUp.

**Источник:** gemini
**Статус:** Автоисправлено
**Ответ:** Обернуть все `UI.messagebox` из save flow в `UI.start_timer(0, false) { ... }` — выходит из action_callback стека до показа.
**Действие:** Design §5.5 + Plan Task 5 — wrapper применён.

### [CRITICAL-4] Task 2 редактирует `application.rb`, Task 3 перезаписывает

> ollama-deepseek: коммит Task 2 «мусорный», промежуточный state файла нигде не существует независимо.
> ollama-kimi: между Task 2 и Task 3 Config accessors == nil — любой запуск SketchUp ломается.

**Источник:** ollama-deepseek, ollama-kimi
**Статус:** Автоисправлено
**Ответ:** Объединил старые Task 2 + Task 3 в новый Task 2 — атомарный коммит: consumers + Application.running_config + boot wiring + Show Status fix + test_application + migration banner call.
**Действие:** Plan — переписан Task 2 как объединённый; нумерация остальных tasks сдвинута (4→3, 5→4, 6→5, 7→6, 8→7, 9→8). Spec coverage таблица обновлена.

### [CRITICAL-5] Нет тестов на `Application.running_config`

> ollama-deepseek: семантика — краеугольный камень IPC; без тестов баги (rescue clearing, restart snapshot) не пойманы.

**Источник:** ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Создан `test/test_application.rb` с 3 тестами через `StubServer`: capture snapshot at start, clear on stop, clear on start failure. Application получил injectable `server_class` для DI.
**Действие:** Plan Task 2 Step 3 (injectable server_class) + Step 5 (test file). Design §7.1 описывает.

### [CONCERN-6] `host` без `.to_s` в `load_from_defaults!`

> gemini, ollama-deepseek: `read_default` может вернуть Integer — `TCPServer.new(123456, 9876)` → TypeError.

**Источник:** gemini, ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Добавлен `.to_s` для host (как уже было для port/log_level).
**Действие:** Design §5.1 + Plan Task 1 Step 3.

### [CONCERN-7] `Show Status` показывает `Config.port` вместо running port

> ollama-kimi: после Save без restart, Show Status показывает свежесохранённое, не фактический running.

**Источник:** ollama-kimi
**Статус:** Автоисправлено
**Ответ:** Использовать `Application.running_config[:host]:running_config[:port]` когда running, иначе "stopped".
**Действие:** Plan Task 2 Step 4 — переписана Show Status логика. Design §5.3 + §5.8.

### [CONCERN-8] `need_restart` сравнивает с last-saved, не с running

> ollama-kimi: revert настроек к running values всё равно вызовет restart prompt.

**Источник:** ollama-kimi
**Статус:** Автоисправлено
**Ответ:** Сравнивать с `Application.running_config` (snapshot **до** `Config.update!`), не с `Config.host`/`Config.port` (последние уже равны new values после update!).
**Действие:** Plan Task 5 — snapshot `current_runtime` берётся до update!. Design §5.5 шаг 7.

### [CONCERN-9] `STYLE_DIALOG` возможно модальный

> ollama-kimi: на некоторых платформах блокирует SketchUp; STYLE_UTILITY типичнее.

**Источник:** ollama-kimi
**Статус:** Отклонено
**Ответ:** Оставляем STYLE_DIALOG. Стандартный modal-style dialog для settings норма (пользователь открывает кратковременно). STYLE_UTILITY больше про tool palettes (persistent always-on-top). Не блокирующий issue.
**Действие:** Нет.

### [CONCERN-10] `ruby -c` syntax checks отсутствуют

> ollama-kimi: тесты не покрывают server.rb/application.rb/logger.rb/main.rb — добавить syntax check.

**Источник:** ollama-kimi
**Статус:** Автоисправлено
**Ответ:** `ruby -c` для всех 5 изменённых .rb файлов (server, application, logger, main, test_application) в Step 6.
**Действие:** Plan Task 2 Step 6.

### [CONCERN-11] Migration: ENV отключается молча

> gemini, ollama-kimi: пользователи с custom ENV-конфигом получат defaults без предупреждения.

**Источник:** gemini, ollama-kimi
**Статус:** Автоисправлено
**Ответ:** При boot show one-time messagebox: если detected ENV `SKETCHUP_MCP_HOST/PORT/LOG_LEVEL` И prefs пусты И флаг `migration_notified` ещё false → показать diff, проставить флаг. ENV сами **не читаются** — только их наличие как сигнал. Совместимо с архитектурным решением "ENV убрать".
**Действие:** Design §6.2 (новая секция). Plan Task 1 — добавлен метод `Config.show_migration_banner!` + 4 теста. Plan Task 2 Step 4 — вызов из main.rb.

### [CONCERN-12] CSS hardcoded px (High-DPI breakage)

> gemini: 4K мониторы при 150-200% scaling — overlap.

**Источник:** gemini
**Статус:** Автоисправлено
**Ответ:** Перевод на em / flex-basis (label `flex: 0 0 8em`, error `margin-left: 8em`, padding в em).
**Действие:** Plan Task 4 — CSS обновлён.

### [CONCERN-13] Rescue ошибка отображается в поле host

> ccs-glm: внутренняя ошибка → "host: Internal error: ..." вводит в заблуждение.

**Источник:** ccs-glm
**Статус:** Автоисправлено
**Ответ:** Использовать ключ `_general` в errors object. HTML/JS extract этот ключ как fallback и показывает под host-error slot с понятным prefix.
**Действие:** Plan Task 5 — rescue использует `_general`. Plan Task 4 (HTML) — JS обрабатывает `_general`.

### [CONCERN-14] `e.message` без санитизации

> ccs-glm: invalid encoding или кавычки могут сломать JSON.generate.

**Источник:** ccs-glm
**Статус:** Автоисправлено
**Ответ:** `e.message.to_s.encode("utf-8", invalid: :replace, undef: :replace)` перед JSON.generate (паттерн уже использован в server.rb).
**Действие:** Plan Task 5 — sanitize в rescue.

### [CONCERN-15] `DIALOG_PREFS` захардкожен

> ccs-glm, ollama-deepseek: использовать `"#{SECTION}_..."` или версию.

**Источник:** ccs-glm, ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** `"#{SU_MCP::Core::Config::SECTION}_SettingsDialog"`. Версионирование (Q ollama-deepseek) — overkill для текущих фикс-размеров диалога, не делаем.
**Действие:** Plan Task 5 — DIALOG_PREFS использует константу.

### [CONCERN-16] Test count в плане неточный

> ccs-glm: фактически 80−8+13+12=97, не 101.

**Источник:** ccs-glm
**Статус:** Автоисправлено
**Ответ:** Обновлён count с учётом добавленных test_application (3), migration banner (4), host charset (2) — итого ~106 runs.
**Действие:** Plan Task 8 Step 1.

### [CONCERN-17] grep ожидание включает `docs/superpowers/`

> ollama-deepseek: план сам содержит примеры с `Config::HOST` (в diff-блоках).

**Источник:** ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Уточнить ожидание — exclude `docs/superpowers/` целиком (там — историческая запись).
**Действие:** Plan Task 8 Step 3.

### [CONCERN-18] Тщательная валидация host (regex)

> gemini: разрешать только IPv4/IPv6/hostname символы.

**Источник:** gemini
**Статус:** Автоисправлено
**Ответ:** Regex `\A[A-Za-z0-9._\-:]+\z` после whitespace/length checks. Отдельный errors key с "Host contains invalid characters".
**Действие:** Plan Task 3 (validator) — regex + 2 теста (invalid chars, IPv6 unbracketed). Design §5.6.

### [CONCERN-19] `EADDRINUSE` при мгновенном рестарте

> gemini: TIME_WAIT может блокировать.

**Источник:** gemini
**Статус:** Отклонено (investigation completed)
**Ответ:** MRI Ruby `TCPServer.new` устанавливает `SO_REUSEADDR` по умолчанию на Linux/macOS/Windows — code change не нужен. Если в реальной эксплуатации проявится — отдельный follow-up.
**Действие:** Design §5.3 + §8 Risks — упомянуто.

### [CONCERN-20] Singleton `show` — stale state при reopen

> gemini: пользователь стопает/стартует сервер через меню, при следующем `show` диалог показывает старое.

**Источник:** gemini
**Статус:** Автоисправлено
**Ответ:** В `show` если `@dialog.visible?` — вызвать `on_load_state(@dialog)` перед `bring_to_front`.
**Действие:** Plan Task 5 — `show` обновлён. Design §5.8.

### [SUGGEST-21] JSON `</` в `<script>` контексте

> ollama-deepseek: XSS-only-self минимальный, но defense in depth.

**Источник:** ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Helper `js_safe_json(value) = JSON.generate(value).gsub("</", "<\\/")`.
**Действие:** Plan Task 5 — helper добавлен, используется во всех `execute_script`.

### [SUGGEST-22] JS comment про `log_level` в `current` payload

> ollama-deepseek: неочевидно почему log_level в state.current не учитывается в savedDiffers.

**Источник:** ollama-deepseek
**Статус:** Автоисправлено
**Ответ:** Inline JS комментарий рядом с `savedDiffers`: "Log-level applies immediately (Logger reads Config.log_level per call); only host/port mismatches drive restart banner."
**Действие:** Plan Task 4 (HTML).

### [SUGGEST-23] `Config.update!` doc-comment про валидацию

> ccs-glm Q2: должен ли update! validate?

**Источник:** ccs-glm
**Статус:** Автоисправлено (comment-only)
**Ответ:** Doc-comment "Caller is responsible for passing pre-validated, normalized values (see SettingsValidator)" в update!. Сам метод не валидирует — это работа SettingsValidator (separation of concerns).
**Действие:** Plan Task 1 + Design §5.1.

### [CONCERN-24] `running_config` не очищается при `reset_client`

> ccs-glm: pre-existing behavior, существующий issue.

**Источник:** ccs-glm
**Статус:** Отклонено (out of scope)
**Ответ:** Existing issue (Server отдельно от Application). Не относится к этому PR.
**Действие:** Упомянуто в §8 Risks как known limitation.

### [CONCERN-25] `load_from_defaults!` при reload плагина

> ccs-glm: Application reset, но Server-таймер может крутиться.

**Источник:** ccs-glm
**Статус:** Отклонено (out of scope)
**Ответ:** Existing reload-issue плагина, отдельный fix.
**Действие:** Нет.

### [CONCERN-26] Logger тесты depend on `Config.log_level`

> ollama-deepseek: если появятся logger тесты, должны инициализировать Config.

**Источник:** ollama-deepseek
**Статус:** Отклонено (currently no logger tests)
**Ответ:** Out of scope. Когда появятся — добавим setup. Сейчас покрытия нет.
**Действие:** Нет.

### [CONCERN-27] `was_running` race в `on_save`

> ollama-deepseek: сервер может остановиться между was_running и UI.messagebox.

**Источник:** ollama-deepseek
**Статус:** Отклонено (edge case acceptable)
**Ответ:** Edge case: restart prompt при остановленном сервере просто запустит его — не разрушительно, лёгкий UX confusion. Acceptable.
**Действие:** Упомянуто в §8 Risks.

### [SUGGEST-28] Поведение после Save без restart — dialog.close?

> gemini Q1, ollama-deepseek concern #5.

**Источник:** gemini, ollama-deepseek
**Статус:** Автоисправлено (Q answered through design)
**Ответ:** Окно НЕ закрывается автоматически. Вместо этого — обновляется state через `on_load_state` (показывает saved values + актуальный running_config). Это даёт пользователю визуальное подтверждение, что save состоялся. Закрытие — только по Cancel или window-X.
**Действие:** Design §5.5 + Plan Task 5 — этот flow явно описан.

### [SUGGEST-29] Export/Import settings

> ccs-glm Q3.

**Источник:** ccs-glm
**Статус:** Отклонено (YAGNI)
**Ответ:** Не планируется в этом PR.
**Действие:** Нет.

### [SUGGEST-30] `@processing` guard при action_callback restart

> ollama-deepseek Q1.

**Источник:** ollama-deepseek
**Статус:** Отклонено (verified safe)
**Ответ:** action_callback выполняется в главном потоке SketchUp; таймер `Server` не может выстрелить во время synchronous кода. Дополнительно, рестарт теперь обёрнут в `UI.start_timer(0, false)` (Critical-3), что ещё лучше разрывает callback-стек до restart.
**Действие:** Нет.

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-11-menu-settings-ui-design.md` | §5.1 (update! runtime-first, .to_s host, доcumentary comment), §5.2 (boot wiring + migration banner), §5.3 (consumers + Show Status using running_config, EADDRINUSE note), §5.5 (Save flow rewritten: on_load_state after save, need_restart vs running_config, UI.start_timer wrap, sanitize/encode), §5.6 (host charset regex + IPv6 note), §5.8 (singleton refresh + Show Status), §6.2 (NEW migration banner), §6.3 (renumbered docs), §6.4 (renumbered packaging), §7.1 (NEW test_application), §7.2-7.5 (renumbered), §8 (Risks table extensively reworked) |
| `docs/superpowers/plans/2026-05-11-menu-settings-ui.md` | File structure updated (test_application.rb added, Application full rewrite). Task 1 +`show_migration_banner!` + 4 tests + runtime-first update! + .to_s host. Tasks 2+3 merged into atomic Task 2 (consumers + running_config + boot + migration call + Show Status fix + test_application + ruby -c). Tasks renumbered 4→3, 5→4, 6→5, 7→6, 8→7, 9→8. Task 3 (validator) +host charset regex + 2 tests. Task 4 (HTML) em/flex-basis CSS + JS comment + `_general` handling. Task 5 (Dialog) full rewrite: js_safe_json helper, current_runtime snapshot, on_load_state after save, restart timer wrap, sanitize e.message, refresh on restart, idempotent show. Task 8 verification counts updated, grep scope clarified. Spec coverage table updated. |

## Статистика

- Всего замечаний: 30
- Автоисправлено: 22
- Обсуждено с пользователем: 0 (все либо явно clear-and-actionable, либо dismiss с обоснованием)
- Отклонено: 8
- Повторов (автоответ): 0
- Пользователь сказал "стоп": Нет
- Агенты: gemini-executor, ccs-executor (glm), ollama-executor (kimi), ollama-executor (deepseek)
- codex-executor: FAILED (auto-mode security blocked `--dangerously-bypass-approvals-and-sandbox`)
- ollama-executor (minimax): PENDING — будет обработан в отдельной мини-итерации после завершения (по запросу пользователя «продолжай, потом посмотри что он написал»).

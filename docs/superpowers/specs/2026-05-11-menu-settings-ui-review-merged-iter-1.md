# Merged Design Review — Iteration 1

## codex-executor (gpt-5.5, xhigh) — FAILED

Codex CLI exec блокируется auto-mode classifier из-за флага `--dangerously-bypass-approvals-and-sandbox`, который требует codex-exec skill. Ревью не выполнено.

---

## gemini-executor

Ознакомившись с дизайн-документом и планом реализации `menu-settings-ui`, я могу отметить, что общая архитектура (замена констант на изменяемые свойства и инъекция зависимостей для тестов) выглядит чистой и продуманной. Однако в плане реализации и взаимодействии с SketchUp API есть несколько существенных недочетов, которые необходимо исправить до начала написания кода.

### Critical Issues
1. **Логическая ошибка в процессе сохранения (Bug in Save flow):** В комментариях JS-кода сказано: `ok === true → Ruby owns the next step (close dialog or restart prompt)`. Однако в Ruby-методе `SettingsDialog.on_save` вызов `dialog.close` отсутствует. Если рестарт не требуется — окно останется открытым без обратной связи. Если рестарт требуется — окно также останется висеть с устаревшим статусом. **Решение:** явно вызывать `dialog.close` или обновлять state через `on_load_state(dialog)`.

2. **Ошибки `Sketchup.write_default` игнорируются:** В SketchUp API `write_default` **не выбрасывает исключений** — возвращает `false`. `Config.update!` игнорирует return value и мутирует runtime. **Решение:** проверять возвращаемое значение.

3. **Блокировка UI на Windows:** `UI.messagebox` напрямую внутри `action_callback` — известная "болячка" SketchUp под Windows (проваливается под главное окно, зависание). **Решение:** обернуть в `UI.start_timer(0, false)`.

### Concerns
1. **Устаревшие данные при повторном открытии диалога (Stale state):** Если пользователь стопнет/стартанёт сервер через главное меню, пока диалог открыт — статус устареет. **Решение:** обновить state в `show` перед `bring_to_front`.

2. **Риск `EADDRINUSE` при мгновенном рестарте:** Если `Server#stop` не использует `SO_REUSEADDR`, порт остаётся в `TIME_WAIT`. Стоит проверить.

3. **Отсутствие приведения типа для `host` при загрузке:** `port` имеет `.to_i`, `log_level` имеет `.to_s.upcase`, а `host` нет. **Решение:** `.to_s` для безопасности.

### Suggestions
1. **Смягчение миграции с ENV:** показать однократный messagebox при старте, если в OS установлен ENV и prefs пусты.
2. **CSS для High-DPI:** жесткие px (label width=110px) криво смотрятся на 4K. Использовать `em` или `flex-basis`.
3. **Ужесточение валидации host:** regex разрешать только IPv4/IPv6/dots/dashes/colons (`^[a-zA-Z0-9\.\-\:]+$`).

### Questions
1. Какое UX-поведение ожидается при успешном Save, если рестарт не нужен?
2. Освобождает ли `Server#stop` TCP-порт моментально?

---

## ccs-executor (glm)

Дизайн в целом продуманный. Основные архитектурные решения оправданы. Несколько проблем для адресации.

### Critical Issues

**1. Неатомарность `Config.update!`** — нарушает собственные гарантии дизайна. Runtime мутируется после трёх `write_default`. Если упадёт 2-й/3-й — prefs частично записаны, runtime нетронут. `rescue` в `on_save` ловит, отправляет ошибку в JS — на перезагрузке prefs остаются несогласованными. **Fix:** мутировать runtime first, либо транзакционно.

**2. Устаревшее состояние диалога после успешного Save** — `applyState` вызывается только при `load_state`. После Save нужен повторный `on_load_state(dialog)`.

### Concerns

**3. В `on_save` rescue ошибка отправляется в поле `host`** — вводит в заблуждение. Лучше отдельный `_general` ключ или messagebox.

**4. `e.message` без санитизации в JS** — если содержит кавычки/спецсимволы, сломает JSON.generate или XSS. Добавить `.encode("utf-8", invalid: :replace)` как в `server.rb:169`.

**5. Арифметика тестов в плане неточна** — фактически 80 − 8 + 13 + 12 = **97**, не 101.

**6. `running_config` не сбрасывается при `reset_client`** — диалог покажет "running on..." для сервера без живого клиента. Существующее поведение, но усилено.

**7. Порядок `load_from_defaults!` при reload** — модули пере-`require`'аются, `@running` сбрасывается, хотя таймер `Server` может ещё крутиться. Pre-existing, но более заметно с `running_config`.

### Suggestions

**8. Добавить `on_load_state(dialog) if result[:ok]`** после успешного Save.

**9. Защитить `Config.update!` от частичного персиста** — swap order или rescue с rollback.

**10. `DIALOG_PREFS` через интерполяцию** — `"#{SECTION}_SettingsDialog"`.

**11. Убрать неиспользуемый log_level из running_config в JS** — либо убрать из payload, либо добавить сравнение.

### Questions

1. **`write_default` → `nil`?** Может ли вернуть nil без исключения (квоты на prefs)?
2. **Должен ли `Config.update!` валидировать входные данные?** Сейчас валидация только в SettingsValidator.
3. **Планируется экспорт/импорт настроек?** Если да — сделать в этом PR.

### Резюме

85% решений верны. Два critical — атомарность update! и stale UI — критичны для UX. Остальное polishing.

---

## ollama-executor (ollama-kimi)

Общая архитектура продумана, IPC чистый, TDD реалистичен. Но есть проблемы.

### Critical Issues

**1. Частичное обновление prefs при падении `write_default`** — runtime мутируется после всех трёх записей. **Fix:** runtime first.

**2. `Show Status` врёт после сохранения без рестарта** — показывает `Config.port`, а не фактический running port. **Fix:** использовать `Application.running_config` в `main.rb` Show Status.

**3. Нерабочее состояние между Task 2 и Task 3** — Task 2 переключает потребителей на акцессоры (которые `nil` пока Task 3 не дёрнул `load_from_defaults!`). Любой запуск SketchUp между коммитами упадёт с `TCPServer.new(nil, nil)`. **Fix:** объединить Task 2 и Task 3.

### Concerns

**1. Миграция: ENV отключается молча** — пользователи с кастомным конфигом не узнают, пока Python не перестанет коннектиться. Решение принято, но насколько громко кричать в release notes.

**2. Диалог не обновляет статус после Save + «No» на restart** — applyState только на DOM ready. Пользователю надо закрыть/открыть, чтобы увидеть актуальный баннер.

**3. `STYLE_DIALOG` может быть модальным** — может блокировать SketchUp. `STYLE_UTILITY` обычно удобнее для settings.

**4. Task 2 не проверяет синтаксис изменённых файлов** — тесты не покрывают `server.rb`, `application.rb`, `logger.rb`, `main.rb`. Добавить `ruby -c`.

### Suggestions

**1. Сравнивать с `running_config` при решении о restart-prompt** — если пользователь revert'нул настройки к running, prompt всё равно вылезет. Сравнивать с running, а не с last-saved.

**2. Обновить `Show Status` заодно с Task 3** — использовать `running_config[:host]:running_config[:port]`.

**3. Добавить `ruby -c` в план** для каждого изменённого `.rb`.

**4. Перестраховать `Config.update!` от частичных записей** — runtime first.

### Questions

1. **Модальность диалога:** STYLE_DIALOG vs STYLE_UTILITY?
2. **Show Status и running_config:** Стоит ли заодно починить Show Status?
3. **Порядок записи в Config.update!:** Согласны поменять?

---

## ollama-executor (ollama-deepseek)

Архитектура структурно здорова. План покрывает все секции дизайна.

### Critical Issues

**1. Task 2 редактирует `application.rb`, Task 3 перезаписывает целиком** — коммит Task 2 «мусорный»: его дифф никогда не существует в working state независимо. При `git bisect` файл будет в промежуточном состоянии. **Fix:** убрать `application.rb` из Task 2.

**2. Нет тестов на `Application.running_config`** — семантика `running_config` — краеугольный камень IPC. Без тестов: потеря running_config=nil при rescue, неверный snapshot при restart — баги не пойманы. **Fix:** создать `test/test_application.rb` с 3 тестами: `test_start_captures_config`, `test_stop_nils_running_config`, `test_start_failure_nils_running_config`.

**3. `Config.update!` не даёт гарантий атомарности** — если (3) бросает после (1)+(2), runtime старый, но prefs частично новые. **Fix:** swap order — сначала runtime, потом write_default.

### Concerns

**4. `host` в `load_from_defaults!` не форсируется в строку** — `read_default` может вернуть Integer, тогда `TCPServer.new(123456, 9876)` → TypeError. **Fix:** `.to_s`.

**5. Диалог не закрывается и не обновляется после restart** — статус показывает старый running on X:Y. **Fix:** `dialog.close` или `on_load_state(dialog)`.

**6. `SKETCHUP_CONSOLE` в тестах Logger** — `Logger` юзает `Config.log_level`; если тесты Logger появятся и Config не инициализирован — упадёт `level_value_for(nil)`. Скрытая зависимость на будущее.

**7. `was_running` semantics в `on_save`** — если сервер падает между `was_running=true` и `UI.messagebox`, пользователь увидит restart prompt для остановленного сервера. Edge case.

### Suggestions

**8. Объединить Tasks 2+3 для application.rb** — убрать application.rb из Task 2.

**9. Добавить test/test_application.rb** — три теста через StubServer.

**10. `JSON.generate` + `<script>` контекст** — `JSON.generate` не экранирует `</` → `<\/`. XSS-only-self, минимальный риск. Опционально — JSON через скрытый элемент.

**11. `SettingsDialog.on_load_state` — избыточная детализация** — log_level в `current` не используется. Комментарий в JS: "Log-level applies immediately; only host/port require restart."

**12. `grep` results — outside `docs/superpowers/`** — план сам содержит примеры с `Config::HOST`. Лучше: "zero matches outside of `docs/superpowers/`".

### Questions

**Q1:** `@processing` guard при вызове restart из action_callback?
**Q2:** `DIALOG_PREFS = "SU_MCP_SettingsDialog_v0.0.1"` для версионирования?

### Вердикт

Дизайн структурно здоров. **Три вещи перед стартом:** убрать application.rb из Task 2, test_application.rb, `.to_s` для host. Остальное — concerns.

---

## ollama-executor (ollama-minimax) — PENDING

Ревью всё ещё выполняется. Будет добавлено отдельно после завершения.

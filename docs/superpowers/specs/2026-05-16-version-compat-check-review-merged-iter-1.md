# Merged Design Review — Version-Compat Check — Iteration 1

**Date:** 2026-05-16
**Design:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
**Plan:** `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
**Reviewers:** codex-executor (gpt-5.5/xhigh), ccs-executor (glm), ollama-executor (kimi, minimax, deepseek)

---

## codex-executor (gpt-5.5 / xhigh)

Идея в целом жизнеспособна: per-message поля выглядят additive для текущего кастомного JSON-RPC канала, а две таблицы с диапазонами можно поддерживать на 5+ релизах, если дисциплина релиза будет жёсткой. Основные проблемы не в базовой архитектуре, а в точках внедрения, диагностическом `get_version` и тестовом плане.

### Critical Issues

**Неверная Ruby-точка проверки в design**
Design всё ещё показывает проверку в `core/server.rb` и bypass по `method != "get_version"`: `design:95`, `design:397`. Это противоречит реальному wire-протоколу: Python всегда шлёт `method: "tools/call"`, а имя инструмента лежит в `params.name`. Plan в этом месте уже ближе к правильному варианту: `plan:706`. Нужно исправить design, иначе исполнитель, следующий spec, сломает bypass для `get_version`.

**Ruby `-32001` потеряет JSON-RPC id**
В плане check вставляется до `request_id = request["id"]`: `plan:695`. Если `Core::Compat.check_python_version` бросит `StructuredError`, rescue построит error response с `id: nil`, хотя исходный запрос имел id. В текущем `dispatch.rb` id присваивается сразу после validation: `dispatch.rb:15`. Исправление: после `validate_envelope!` сначала выставить `request_id`/`is_notification`, затем делать compat-check.

**`server_version` не покрывает encoding fallback**
План утверждает, что инъекция первой строкой `write_response` покрывает fallback: `plan:724`. Но реальный fallback создаётся внутри `encode_response_body` и возвращает новый JSON без уже добавленного поля: `server.rb:165`. В результате matched pair может получить error envelope без `server_version`, а Python замаскирует исходную ошибку как version mismatch. Нужно декорировать и fallback envelope, либо вынести построение error hash наружу до `JSON.generate`.

**`get_version` не "always succeeds" и может врать о compatible**
Plan ловит только `ConnectionError`: `plan:1263`. Новый Python против старого 0.0.3 Ruby получит `unknown tool: get_version` как `SketchUpError`, и диагностический tool упадёт вместо payload. Кроме того, compatible считается только через `check_ruby_version(ruby_version)`: `plan:1279`, игнорируя Ruby-advertised `min_compatible_python` / `max_compatible_python`. При рассинхроне таблиц `get_version` может сказать `compatible=true`, хотя Ruby блокирует обычные вызовы.

**Task 4 не может пройти в заявленном порядке**
`test/test_server_compat.rb` требует `handlers/system`: `plan:554`, но `handlers/system.rb` создаётся только в Task 5: `plan:821`. Более того, тест `make_server_double` переопределяет `write_response` и дублирует будущую production-логику: `plan:670`. Такой тест пройдёт даже если `core/server.rb` вообще не изменён.

**Plan не учитывает поломку существующих тестов**
После строгого inbound-check текущие `tests/test_connection.py` responses без `server_version` начнут падать, например happy path: `test_connection.py:36`. На Ruby стороне `test/test_view.rb` вызывает `Dispatch.handle` без `client_version`: `test_view.rb:264`. Поэтому расчёт "81 + новые = 102 passed" в `plan:1509` нереалистичен без обновления baseline fixtures.

### Concerns

**Hard-fail на MCP-границе неоднозначен**
Внутри `connection.py` будет raise, но текстовые tools проходят через `_call`, который ловит `SketchUpError` и возвращает форматированную строку: `tools.py:57`. Это может быть приемлемо как user-visible hard fail, но это не MCP tool error.

**`get_version` не добавлен в retry-safe список**
`get_version` read-only и должен быть самым надёжным диагностическим вызовом, но `_RETRY_SAFE_TOOLS` его не содержит: `connection.py:43`. После idle stale-socket он не получит безопасный retry.

**Парсер версий мягче, чем заявлено**
Python `int(...)` и Ruby `Integer(...)` принимают варианты вроде пробелов/плюса, хотя docs обещают строгий `X.Y.Z` numeric shape: `design:53`. Если нужна строгая форма, лучше regex `\A\d+\.\d+\.\d+\z` на обеих сторонах.

**Notifications не описаны**
Ruby сейчас корректно не отвечает на notifications без `id`: `dispatch.rb:42`. Но acceptance criteria говорят "Ruby returns JSON-RPC error" на mismatch: `design:663`. Нужно явно сказать: для notifications compat-check может логироваться, но ответа быть не должно.

### Suggestions

**Сначала выровнять spec и plan**
Зафиксировать единый вариант: Ruby check в `Dispatch.handle` после `validate_envelope!`, после сохранения `request_id`, bypass только для `method == "tools/call" && params.name == "get_version"`. Design-раздел `8.2` надо переписать под это.

**Переставить Ruby задачи**
Сделать `handlers/system.rb` и route до server-compat integration tests, либо убрать `get_version` route из Task 4 tests. Тест `write_response` должен вызывать production method с подставленным `@client` и стабом `IO.select`, а не переопределять сам метод.

**Усилить `get_version`**
Ловить `SketchUpError` тоже, возвращать `ruby_version: null`, `compatible: false`, `error`. Проверять обе стороны: Python accepts Ruby version и Ruby-advertised range accepts `PYTHON_VERSION`; вернуть также `min_compatible_python` / `max_compatible_python`.

**Обновить существующие fixtures**
Сделать helper `encode_response(..., server_version=compat.MAX_RUBY)` в Python tests и точечно тестировать missing field. В Ruby dispatch tests добавить `client_version` ко всем обычным запросам, а missing-client-version оставить отдельным negative case.

### Questions

**Что именно означает `compatible` в `get_version`: только "Python принимает Ruby" или "оба advertised диапазона принимают друг друга"?** Второй вариант полезнее как диагностика и использует поля, которые Ruby уже возвращает.

**Должен ли новый Python против старого 0.0.3 Ruby возвращать payload из `get_version`, даже если Ruby отвечает `unknown tool`?** Сейчас план обещает "always succeeds", но кодовый sketch этого не выполняет.

**Хотите ли вы, чтобы version mismatch был настоящим MCP error для всех tools, или текущая строка `[-32001] ...` для text tools считается достаточным hard-fail UX?**

---

## ccs-executor (glm-5.1)

### Critical Issues

#### C1. Существующие тесты `test_connection.py` сломаются — не учтено в плане

`tests/test_connection.py` содержит ~20 тестов, которые используют `fake_streams`/`make_connection` из `conftest.py` и скармливают mock-ответы через `encode_response()`. Ни один из этих ответов не содержит `server_version`. После выполнения Task 6, `_send_once` будет вызывать `compat.check_ruby_version(response.get("server_version"))` на каждом ответе — `None` будет вызывать `IncompatibleVersionError` с сообщением "pre-dates".

План ожидает «92 + 6 = 98 passed», но это невозможно: все существующие тесты в `test_connection.py` упадут. В разделе «Files to MODIFY» `tests/test_connection.py` и `tests/conftest.py` не упоминаются.

**Почему это критично:** план заявляет «no regressions» после каждого таска, но Task 6 сломает 20+ тестов. Нужно либо обновить `encode_response()` в `test_connection.py` (добавив `"server_version": "0.0.3"`), либо модифицировать `conftest.py::fake_streams`.

#### C2. `get_version` отсутствует в `_RETRY_SAFE_TOOLS`

`connection.py:43-54` определяет `_RETRY_SAFE_TOOLS` — whitelist read-only инструментов, для которых безопасен retry при stale-socket. `get_version` — read-only диагностический инструмент без побочных эффектов, но план не добавляет его в этот список.

**Почему это критично:** при stale-socket во время вызова `get_version` (что вероятно, т.к. его часто вызывают первым при диагностике) retry не произойдёт, и `_StaleSocketError` пробросится наверх.

#### C3. Имя `RUBY_VERSION` в `compat.rb` затеняет глобальную константу Ruby

`SU_MCP::Core::Compat::RUBY_VERSION` затеняет `::RUBY_VERSION` — общеизвестную константу версии интерпретатора Ruby. Внутри модуля `Compat` bare-ссылка `RUBY_VERSION` разрешится в версию плагина, а не версию Ruby. Это работает корректно сейчас, но создаст тонкий баг для будущего разработчика, который добавит код внутри `Compat`, ожидающий `::RUBY_VERSION`.

**Почему это критично:** затенение стандартной константы — это мина замедленного действия. Ruby не выдаёт предупреждения. Следует переименовать в `PLUGIN_VERSION` или `SERVER_VERSION`.

#### C4. Расхождение design → plan: место проверки `client_version`

Дизайн (§8.2) показывает проверку `client_version` в `core/server.rb`:
```ruby
method = req["method"]
client_version = req["client_version"]
if method != "get_version"
  SU_MCP::Core::Compat.check_python_version(client_version)
end
```

План (Task 4.3) перемещает проверку в `handlers/dispatch.rb::handle` (после `validate_envelope!`). Это фактически лучший выбор, но план не признаёт это расхождение. Дополнительно, дизайн показывает `if method != "get_version"`, но Python отправляет `method: "tools/call"`, а не `method: "get_version"` — в дизайне был баг проверки не того поля. План это исправил (`request.dig("params", "name") == "get_version"`), но не отметил исправление.

**Почему это критично:** кросс-референс между документами будет запутан для будущего читателя.

### Concerns

#### W1. Fallback в `encode_response_body` теряет `server_version`

`server.rb:143-177`: план добавляет `response["server_version"] = Core::Compat::RUBY_VERSION` как первую строку `write_response`, затем вызывает `encode_response_body(response)`. Если `JSON.generate` выбросит `JSON::GeneratorError`, fallback на строке 174 создаст **новый** response через `Errors.build_error_response(...)`, в котором `server_version` не будет.

#### W2. Тестовый double в `test_server_compat.rb` дублирует production-код

`make_server_double` в Task 4.1 переопределяет `write_response` с собственной копией инъекции `server_version`. Если production-логика инъекции изменится, тест продолжит проходить, т.к. проверяет свою копию.

#### W3. План использует name-based bypass вместо параметра из дизайна

Дизайн (§7.3) определяет `skip_version_check` как keyword-аргумент на `_raw_call`. План отбрасывает его в пользу проверки `if name != "get_version"` внутри `_send_once`. Это проще, но создаёт скрытую связь.

#### W4. Дублирующее присваивание `method` в `dispatch.rb`

План (Task 4.3, step 4.3) вставляет `method = request["method"]` перед `request_id = request["id"]`, но существующий код на строке 17 уже содержит `method = request["method"]`.

#### W5. Дизайн §6 показывает неверный формат запроса

Дизайн показывает `{"method": "get_model_info", ...}`, реальный формат — `{"method": "tools/call", "params": {"name": "get_model_info", ...}}`.

#### W6. `_parse()` вызывается на константы при каждой проверке

`check_ruby_version` и `check_python_version` вызывают `_parse(MIN_RUBY)`/`_parse(MAX_RUBY)` при каждом вызове.

### Suggestions

#### S1. Добавить `get_version` в `_RETRY_SAFE_TOOLS`
#### S2. Переименовать `RUBY_VERSION` → `PLUGIN_VERSION` в `compat.rb`
#### S3. Учесть обновление `test_connection.py` в плане
#### S4. Добавить тест `MAX_RUBY == PYTHON_VERSION` и `MAX_PYTHON == RUBY_VERSION`
#### S5. Исправить fallback в `encode_response_body` — реинжектить `server_version`
#### S6. Устранить дублирующее `method = request["method"]` в плане
#### S7. Явно зафиксировать design → plan расхождения в плане

### Questions

#### Q1. Был ли осознанный выбор поместить проверку `client_version` в `dispatch.rb`, а не в `server.rb`?
#### Q2. Учтено ли, что encoding-fallback в `write_response` теряет `server_version`?
#### Q3. Согласован ли подход к обновлению существующих mock-ответов в `test_connection.py`?

**Итог:** дизайн в целом продуманный. Основная проблема плана — пропуск обновления существующих тестов (`test_connection.py`).

---

## ollama-executor (kimi K2.6 cloud)

### Critical Issues

#### CI-1: `get_version` не ловит `SketchUpError` — падает на старом Ruby и на любой JSON-RPC error от Ruby

В `tools.py` `get_version` обёрнут только в `try … except ConnectionError`. Если Ruby pre-0.1.0 (не знает инструмента `get_version`), `dispatch.rb` вернёт `-32601 "unknown tool"`. `_raw_call` → `_send_once` увидит `"error" in response` и выбросит `SketchUpError`. `get_version` его не перехватывает.

Это прямо противоречит acceptance criteria: *"get_version returns a payload with compatible: bool … on every call regardless of mismatch state"*.

#### CI-2: `server_version` теряется в fallback `encode_response_body`

План предлагает инъекцию `server_version` в `write_response` одной строкой перед `encode_response_body`. Но `encode_response_body` имеет rescue: если `JSON.generate(response)` падает, fallback создаёт **новый** Hash через `Errors.build_error_response`. Поле `server_version` из оригинального `response` не переносится в fallback-envelope.

#### CI-3: Notification с version-mismatch получит ответ с `"id": nil`

В плане version-check вставляется **перед** `request_id = request["id"]` и `is_notification = !request.key?("id")`. Если `check_python_version` выбрасывает `StructuredError(-32001)`, управление переходит в `rescue`, где используется `request_id` (всё ещё `nil`). Для JSON-RPC notification (нет `"id"`) Ruby отправит error response с `"id": nil`, нарушая spec: *"The Server MUST NOT reply to a Notification"*.

#### CI-4: `get_version` обещано как bypass, но `_send_once` всё равно выбросит `SketchUpError` на Ruby-side error

Даже с bypass для `get_version`, если Ruby вернёт JSON-RPC error envelope, `_send_once` выполнит `raise SketchUpError(...)` после bypass-блока.

### Concerns

#### C-1: Два одинаковых MIN/MAX ("0.0.3".."0.0.3") = exact match, а не range
Политика `MIN == MAX` делает несовместимыми даже патч-релизы.

#### C-2: `get_version` отсутствует в `_RETRY_SAFE_TOOLS`

#### C-3: Тест `test_get_version_works_when_other_tools_blocked` есть в дизайне, но нет в плане

#### C-4: Mock `_frames_to_reader` неточен
`readexactly(n)` возвращает `buf[pos:pos+n]` без проверки, что `n` <= остаток.

#### C-5: `make_server_double` дублирует production-логику

#### C-6: Per-message hard-fail без hint на `get_version`
Пользователь Claude Desktop увидит wall of identical errors. Стоит добавить в текст ошибки однострочный hint.

#### C-7: `client_version` добавляет ~20 байт к payload перед size-check

### Suggestions

#### S-1: Добавить `except SketchUpError` в `get_version`
#### S-2: Перенести `server_version` injection в `encode_response_body`
#### S-3: Определять `is_notification` до version-check в `dispatch.rb`
#### S-4: Добавить `get_version` в `_RETRY_SAFE_TOOLS`
#### S-5: Явно задокументировать exact-match политику MIN/MAX
#### S-6: Добавить тест на `server_version` в fallback response

### Questions

#### Q-1: Какова реальная политика для MIN/MAX после 1.0.0?
#### Q-2: Что ожидается для concurrent reconnect при mismatch?
#### Q-3: Как `get_version` отображается в MCP UI? Возвращает raw JSON string.
#### Q-4: Почему Ruby-side `check_python_version` выбрасывает `StructuredError`, а не отдельный exception-класс?

---

## ollama-executor (minimax M2.7 cloud)

### Критические проблемы

#### 1. `server_version` НЕ инжектится в fallback-ответ об ошибке

В `write_response` инъекция `server_version` происходит **до** `encode_response_body`. Но `encode_response_body` при `JSON::GeneratorError` **заменяет** `response` новым словарём без `server_version`. Тест `test_write_response_injects_server_version_on_error` в плане ожидает, что error-ответ содержит `server_version`, но код этого не гарантирует.

#### 2. `test_write_response_injects_*` тестирует double, а не production-код

`make_server_double` **полностью переопределяет** `write_response` внутри test double — включая строку инъекции `server_version`. Если разработчик пропустит изменение production `write_response` в Step 4.4, тесты Steps 4.5 и 4.6 всё равно пройдут.

#### 3. Wire-level bypass check в design doc противоречит плану

Design doc показывает `if method != "get_version"`, план — `method == "tools/call" && params.name == "get_version"`. В реальном wire-протоколе метод **всегда** `"tools/call"`. Design doc даёт неправильную логику.

### Замечания

#### 4. `connection.py`: response может не быть dict перед check_ruby_version
Если `json.loads(response_body)` вернёт не-dict, `response.get("server_version")` выбросит `AttributeError` до версионного check.

#### 5. Потенциальный race при split-version bump
Если разработчик по ошибке bump'нет одну сторону раньше другой, ranges не пересекаются и handshake фейлится.

#### 6. Asymmetric behavior при old Ruby + new Python
Ruby отвергает запрос с `StructuredError(-32001)` (с `server_version: "0.0.3"` в ответе). Python получает `SketchUpError(-32001, ...)` — **не** `IncompatibleVersionError`. Сообщения дают правильный guidance, но реализация отличается.

#### 7. Test count неточность в плане
Фактически ~20 new, не ~21-24.

### Предложения

#### 8. Добавить guard для fallback-encoding в `write_response`
#### 9. В `test_server_compat.rb` — проверить production-код напрямую
#### 10. `server_version` в `Errors.build_error_response`

### Вопросы

#### 11. Что происходит если `encode_response_body` подменяет response в success path?
#### 12. Почему в design нет отдельного теста на encoding fallback + server_version?

**Резюме:** Три реальные проблемы: (1) `server_version` теряется в encoding fallback, (2) тесты double не верифицируют production code напрямую, (3) расхождение design doc и плана по bypass check.

---

## ollama-executor (deepseek V4 Pro cloud)

### Критические проблемы

#### 1. `dispatch.rb` — `request_id = nil` в rescue-блоке при version-mismatch

План размещает проверку `check_python_version` **до** строки `request_id = request["id"]`. При срабатывании `StructuredError(-32001)` rescue-блок в `dispatch.rb:44` использует переменную `request_id`, которая всё ещё содержит `nil`. Ответ уходит с `"id": null` вместо реального id запроса — нарушает JSON-RPC 2.0.

#### 2. `get_version` tool не ловит `SketchUpError`

Обёртка `get_version` ловит только `ConnectionError`, но `_raw_call` может выбросить `SketchUpError` если Ruby-обработчик `get_version` упал. Прямое нарушение acceptance criteria.

#### 3. Task 4 и Task 5 — скрытая зависимость, ломающая TDD

`test/test_server_compat.rb` (Task 4) содержит `require_relative "../su_mcp/su_mcp/handlers/system"` и тест `test_dispatch_get_version_bypasses_client_version_check`. Этот тест НЕ может пройти в шаге 4.5, потому что:
- Файл `handlers/system.rb` не существует до Task 5 → **LoadError**.
- Маршрут `when "get_version"` в `call_handler` добавляется только в Task 5.

План утверждает в шаге 4.5: «Expected: all tests green», но это недостижимо.

#### 4. `get_version` отсутствует в `_RETRY_SAFE_TOOLS`

`get_version` — чисто диагностический, read-only, без побочных эффектов — но не добавлен в whitelist.

### Серьёзные замечания

#### 5. Несогласованность: bypass-логика в дизайне и плане
Design §8.2 показывает упрощённый псевдокод `if method != "get_version"`, что не соответствует реальному wire-протоколу.

#### 6. `remove_const` / `const_set` в Ruby-тестах — хрупкий паттерн
- Если исключение между `remove_const` и `const_set`, ensure-блок попытается `remove_const` несуществующую константу.
- Ruby выдаст warnings «already initialized constant».

#### 7. `IncompatibleVersionError` и `SketchUpError` — disconnect при version-mismatch
Любой путь, где Ruby возвращает JSON-RPC error, вызывает `disconnect()` — соединение рвётся.

#### 8. Тест `test_python_version_is_imported_from_init` — недостаточная строгость
Не проверяет, что `PYTHON_VERSION` действительно импортирован, а не захардкожен.

### Предложения

#### 9. Упростить: одна таблица совместимости вместо двух
Можно вынести `MIN_COMPAT`, `MAX_COMPAT` в JSON-файл, который читается обеими сторонами при старте. Это устранит риск рассинхронизации.

#### 10. Добавить тест на форму `_send_once` при version-mismatch без disconnect
#### 11. Валидация `client_version` на строковость в Ruby (снято — уже валидируется)
#### 12. Именование тестового файла: `test_server_compat.rb` vs `test_server.rb` (консистентно)

### Вопросы

#### 13. Почему `get_version` возвращает `str` (JSON-строка), а не `dict`?
#### 14. Что произойдёт с версионной проверкой при JSON-RPC notifications?

---

## Итог

Все 5 ревьюеров согласны в нескольких ключевых местах:
1. **`server_version` теряется в encoding fallback** — 4/5 (codex, ccs-glm, kimi, minimax)
2. **Wire-level bypass: design противоречит плану** — 4/5 (codex, ccs-glm, minimax, deepseek)
3. **`get_version` не ловит `SketchUpError`** — 3/5 (codex, kimi, deepseek)
4. **`request_id = nil` в rescue при version-mismatch** — 3/5 (codex, kimi, deepseek)
5. **`get_version` отсутствует в `_RETRY_SAFE_TOOLS`** — 4/5 (codex, ccs-glm, kimi, deepseek)
6. **Тестовый double дублирует production-код** — 4/5 (codex, ccs-glm, kimi, minimax)
7. **Task 4/5 циклическая зависимость** — 2/5 (codex, deepseek)
8. **`test_connection.py` сломается после Task 6** — 2/5 (codex, ccs-glm)
9. **`RUBY_VERSION` shadows `::RUBY_VERSION`** — 1/5 (ccs-glm)
10. **Notifications + version-mismatch не описаны** — 3/5 (codex, kimi, deepseek)

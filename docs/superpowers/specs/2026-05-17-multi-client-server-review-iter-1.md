# Review Iteration 1 — 2026-05-17

## Источник

- **Design:** `docs/superpowers/specs/2026-05-17-multi-client-server-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-17-multi-client-server.md`
- **Review agents:** codex-executor (gpt-5.5, xhigh), ccs-executor (glm — GLM-5.1), ollama-executor (minimax — M2.7), ollama-executor (deepseek — V4 Pro)
- **Note:** ollama-kimi был запущен, но watchdog застрял (event_count=30 без прогресса 9+ минут, output.txt не создан) — исключён из merged set.
- **Merged output:** `docs/superpowers/specs/2026-05-17-multi-client-server-review-merged-iter-1.md`

## Замечания

### CRITICAL-1 — Python `_handshake()` без таймаута

> codex / glm / deepseek: `connect()` не оборачивает `_handshake()` в `asyncio.wait_for`; если Ruby принял TCP но не отвечает, клиент блокируется навсегда.

**Источник:** codex, glm, deepseek (multi-agent consensus)
**Статус:** Автоисправлено
**Ответ:** Очевидное решение — единственное разумное. Завернул `_handshake()` в `asyncio.wait_for(..., timeout=self.timeout)` в design §6.4 и plan Task 6 Step 4b/4c. Дополнительно нормализованы все malformed-envelope пути в `SketchUpError` (`json.JSONDecodeError`, не-Hash `response`, не-Hash `error` или `result`).
**Действие:** design §6.4 + plan Task 6 step 4b/4c — асинхронный таймаут и нормализация ошибок.

---

### CRITICAL-2 — Handshake reply через `Dispatch.build_success_response` ломает Python-клиента

> codex: `build_success_response` оборачивает в MCP `content` shape (`{content:[{type:text,text:...}], isError:false}`), а Python `_handshake()` ожидает `result.server_version` напрямую.

**Источник:** codex (+косвенно: minimax Q1)
**Статус:** Автоисправлено
**Ответ:** Подтверждено grep'ом `dispatch.rb:90` — `build_success_response` действительно вызывает `wrap_content`. Заменил вызов на raw JSON-RPC envelope inline в design §5.3 и plan Task 5 Step 3b. Добавил комментарий, объясняющий почему именно inline.
**Действие:** design §5.3 + plan Task 5 step 3b.

---

### CRITICAL-3 — Smoke `boolean_operation` параметры не существуют

> deepseek: HEAVY_WORKLOAD использует `target_name` / `tool_name`, а реальный MCP-tool принимает `target_id` / `tool_id` (entity ID).

**Источник:** deepseek
**Статус:** Автоисправлено
**Ответ:** Подтверждено grep'ом `tools.py:250` (`target_id`/`tool_id`). Убрал `boolean_operation` из HEAVY_WORKLOAD (требовал бы предварительного `find_components` для получения ID — лишняя сложность). Заменил на симметричный набор create_component × 2 + get_model_info + delete_component × 2 — нагрузка остаётся «тяжёлой», но не зависит от резолва ID.
**Действие:** plan Task 8 (HEAVY_WORKLOAD).

---

### CRITICAL-4 — `close_client` оставляет state в `@clients` при повторном вызове закрытого клиента

> codex: `return if state.closed?` срабатывает ДО `@clients.delete(state.sock)`. Если сокет закрыт извне (EOFError/ECONNRESET), state остаётся в `@clients` навсегда.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Изменил инвариант: `@clients` membership — source of truth для «still tracked»; `state.closed?` определяет только нужно ли вызывать `sock.close`. Идемпотентность сохраняется через `return unless @clients.key?(state.sock)`.
**Действие:** design §5.4 + plan Task 4 (close_client).

---

### CRITICAL-5 — Task 5 Step 6 retrofit ломает `disconnect_mid_queue` test coverage

> codex / glm / minimax: после prepend HELLO в test_disconnect_mid_queue, wrap срабатывает на handshake-ответе (id=0), а не на A1 (id=1). Парентетическая ремарка в плане признаёт противоречие, но не решает его.

**Источник:** codex, glm, minimax (multi-agent)
**Статус:** Автоисправлено
**Ответ:** Переписал инструкцию retrofit'а — wrap теперь срабатывает только на первый **post-handshake** response (`response["id"] != 0`). Ожидаемые frames: `[0, 1]` (hello reply + A1 reply), A2/A3 пропускаются. Сохраняет первоначальный intent теста.
**Действие:** plan Task 5 step 6 (test_disconnect_mid_queue retrofit).

---

### CRITICAL-6 — Дизайн обещает `test_stale_socket_retry_redoes_handshake`, в плане его нет

> codex: design §10.3 явно перечисляет тест; план шести Python-тестов его не содержит. Пропуск coverage'а для retry-path после handshake-gate.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Добавил тест в plan addendum G + helper `FakeServerMulti` для серверов, обслуживающих несколько последовательных TCP-соединений с разными скриптами.
**Действие:** plan Review Iteration 1 addendum, секция G.

---

### CRITICAL-7 — `write_response` не обрабатывает `Framing.encode_frame` failure

> codex: oversized response body поднимает `StructuredError` из framing; текущий rescue ловит только EPIPE/ECONNRESET/IOError, и StructuredError пробивается в `on_timer_tick`'s top-level rescue — клиент остаётся без ответа.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Добавил inline `begin/rescue StructuredError` вокруг `Framing.encode_frame(body)` с двухступенчатым fallback: (1) пытаемся отправить small `-32603 "response too large"`, (2) если даже fallback не кодируется — закрываем клиента с `reason="encode_frame_failed"`.
**Действие:** design §5.3 + plan Task 5 step 3c.

---

### CRITICAL-8 — `send_transport_error` early-return guard

> minimax: `return if state.closed?` может оставить клиента без `-32600` envelope, если сокет был закрыт между framing-error и call to `send_transport_error`.

**Источник:** minimax
**Статус:** Отклонено
**Ответ:** Сценарий не возникает в нормальном потоке: `state.closed?` становится `true` только после успешного `close_client`, который сам вызывается из `drain_one_client` ТОЛЬКО после `send_transport_error`. Между framing error detection и `send_transport_error` нет другого пути, который бы закрыл клиента. Guard — defensive defensive-in-depth; убирать его — cosmetic.
**Действие:** none.

---

### CONCERN-1 — `accept_pending_clients` потенциально бесконечный loop под Windows

> codex / glm: Windows kernel может держать aborted connections в backlog; `Errno::ECONNABORTED` повторяется без `IO::WaitReadable` — таймер блокирует UI.

**Источник:** codex, glm
**Статус:** Автоисправлено
**Ответ:** Добавил `ACCEPT_ABORTED_MAX = 10` и счётчик `aborted` в `accept_pending_clients`. После 10 подряд ECONNABORTED loop выходит — обработает остаток на следующем тике.
**Действие:** design §5.3 + plan Review Iteration 1 addendum B.

---

### CONCERN-2 — `setsockopt(SO_KEEPALIVE)` leak при исключении

> codex: setsockopt вызывается до `@clients[sock] = state`. Если бросит — сокет принят, но не закрыт и не зарегистрирован → fd leak.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Обернул `setsockopt` в `begin/rescue StandardError`. При исключении сокет закрывается (best-effort) и НЕ регистрируется — инвариант «registered-or-closed» сохранён. Добавил тест в addendum B.
**Действие:** design §5.3 + plan addendum B.

---

### CONCERN-3 — Design line 114 говорит «Dispatch принимает ClientState», но решение отвергнуто

> codex: inventory section §4 противоречит session-decision о handler context.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Изменил формулировку line 114 на «remove per-request version check + get_version bypass; handlers do NOT receive ClientState (see §8.4)».
**Действие:** design §4.

---

### CONCERN-4 — Plan пропускает обновление `src/sketchup_mcp/tools.py` для `get_version`

> codex: design §6.2 говорит, что `get_version` теряет bypass-семантику; план не содержит шага по правке docstring/comments в tools.py.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Добавил step 5b в Task 6 (addendum H): обновить description `get_version` tool в tools.py, убрать «bypass»/«only diagnostic» фразы.
**Действие:** plan addendum H.

---

### CONCERN-5 — FIFO-тесты не доказывают cross-client ordering

> codex: каждый FakeSocket имеет независимый write-buffer; assertions проверяют только per-socket response IDs.

**Источник:** codex
**Статус:** Отклонено
**Ответ:** Текущие тесты достаточны для проверки design intent: «frames dispatched in decoded-arrival order; within-tick starvation accepted». Ruby Hash insertion-order детерминированный, что покрывает «accept-order, then decode-order within client». Введение shared event log — gold-plating, не оправдано session-philosophy «simplicity > strict-correctness-pedantry».
**Действие:** none.

---

### CONCERN-6 — Нет тестов на multi-tick decode ordering / partial frame completion

> codex: «B декодирует фрейм до того, как A завершит» — центральный сценарий FIFO; не покрыт.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Добавил `test_frame_split_across_ticks_dispatches_after_completion` в addendum E: фрейм режется на prefix/suffix, prefix подаётся в tick 1 (ничего не диспатчится), suffix в tick 2 (фрейм собран, диспатчится).
**Действие:** plan addendum E.

---

### CONCERN-7 — Framing-error envelope delivery не ассертится до close

> codex / minimax: `test_framing_oversize_closes_only_that_client` не проверяет, что A получил `-32600` envelope ДО закрытия.

**Источник:** codex, minimax
**Статус:** Автоисправлено
**Ответ:** Добавил `test_framing_oversize_writes_envelope_before_close` в addendum E с assert `frames[0]["error"]["code"] == -32600`.
**Действие:** plan addendum E.

---

### CONCERN-8 — Mid-frame disconnect (EOF после header) не тестируется

> codex: EOF без partial-frame покрыт; EOF после header/посередине body — отдельный state-machine path.

**Источник:** codex
**Статус:** Автоисправлено
**Ответ:** Добавил `test_partial_frame_eof_closes_client` в addendum E.
**Действие:** plan addendum E.

---

### CONCERN-9 — `test_post_handshake_response_has_no_server_version_field` проверяет следствие, не причину

> minimax: тест проверяет refute key для post-handshake, но не положительно ассертит наличие `server_version` в handshake reply.

**Источник:** minimax
**Статус:** Автоисправлено
**Ответ:** Расширил тест положительным ассертом `frames[0]["result"]["server_version"] == Compat::SERVER_VERSION` (addendum F).
**Действие:** plan addendum F.

---

### CONCERN-10 — `test_server_level_error_in_tick_does_not_reset_clients` shallow

> minimax: тест покрывает только top-level rescue, не реальный сценарий «accept успешен, post-accept setsockopt падает».

**Источник:** minimax
**Статус:** Автоисправлено
**Ответ:** Не модифицирую существующий тест (он валиден сам по себе для top-level error path), но добавил **отдельный** тест `test_setsockopt_failure_closes_sock_and_skips_registration` в addendum B, который покрывает именно сценарий setsockopt-leak. Это естественнее: два теста для двух распознаваемых режимов отказа.
**Действие:** plan addendum B.

---

### CONCERN-11 — Plan не включает тест `@close_after_response` + write failure

> minimax: rescue-ветка `write_response` не проверяет флаг.

**Источник:** minimax
**Статус:** Автоисправлено
**Ответ:** Добавил `test_handshake_rejection_with_epipe_still_closes_client` в addendum F: handshake mismatch + write раскидывает EPIPE → клиент всё равно закрывается через rescue path (флаг не нужен, потому что `close_client` уже в rescue).
**Действие:** plan addendum F.

---

### CONCERN-12 — Decoded frames перед framing-error в одном chunk теряются

> codex (concern), glm (изначально critical, отозвал)

**Источник:** codex
**Статус:** Обсуждено с пользователем (auto-decided)
**Ответ:** Подтверждено чтением `framing.rb` — `FrameReader#feed` собирает `completed = []` внутри loop'а, но возвращает только после loop'а; raise посередине теряет накопленное. Выбран **Вариант A** (обновить wording дизайна, без code change): code-change варианты добавляют сложность для corner case'а, который user уже толерирует (FIFO/starvation philosophy). Update §5.3: «framing error invalidates entire chunk — earlier decodes discarded because stream is desynced after bad length prefix».
**Действие:** design §5.3 (wording update).

---

### CONCERN-13 — `test_connect_sends_hello_first_with_client_version` flaky из-за `sleep(0.05)`

> deepseek: hardcoded sleep недетерминирован.

**Источник:** deepseek
**Статус:** Автоисправлено
**Ответ:** Рекомендация в addendum G: `asyncio.Event` синхронизация (предпочтительно), либо bounded busy-loop `for _ in range(10): if len(fs.received) >= expected: break; await asyncio.sleep(0.01)` как минимум-приемлемый вариант.
**Действие:** plan addendum G.

---

### CONCERN-14 — Промежуточное состояние Task 4 → Task 5 ломает e2e

> codex / glm / minimax: после Task 5 commit Python ещё не обновлён, Ruby требует hello — e2e сломан до Task 6.

**Источник:** codex, glm, minimax
**Статус:** Отклонено
**Ответ:** Сознательное решение, явно документировано в плане (Task 4 context paragraph). Это feature-ветка одного разработчика; никто не запустит smoke между коммитами. Усиливать commit-message warning'ами — лишний шум. Оставлено как есть.
**Действие:** none.

---

### CONCERN-15 — `send_transport_error` → double `client_disconnected` в логе

> glm (critical → понизил), deepseek (concern): half-open сокет на framing-error может вызвать double-close.

**Источник:** glm, deepseek
**Статус:** Отклонено
**Ответ:** Снимается фиксом CRITICAL-4: новая `close_client` идемпотентна по `@clients` membership — второй вызов early-return'ит ДО логирования. Double-log невозможен.
**Действие:** покрыто фиксом CRITICAL-4.

---

### SUGGESTION-1 — `@close_after_response` shim → `attr_accessor`

> glm / deepseek: instance_variable_set/get хрупко.

**Источник:** glm, deepseek
**Статус:** Автоисправлено
**Ответ:** Добавлен `attr_accessor :close_after_response` в ClientState (design §5.1 + plan addendum A); `reject_handshake` и `write_response` теперь используют accessor вместо ivar magic. Добавлен соответствующий test_close_after_response_starts_false_and_is_mutable.
**Действие:** design §5.1 + plan addendum A.

---

### SUGGESTION-2 — Вынести `fr`/`all_frames` в `test/support/frame_helpers.rb`

> glm / deepseek: дублирование в двух test-файлах.

**Источник:** glm, deepseek
**Статус:** Автоисправлено
**Ответ:** Создан `test/support/frame_helpers.rb` с модулем `FrameHelpers`; оба test-файла должны `include FrameHelpers`. Plan addendum C.
**Действие:** plan addendum C.

---

### SUGGESTION-3 — Восстанавливать `io_select_writable?` в teardown

> glm: monkey-patch протекает между test-файлами.

**Источник:** glm
**Статус:** Автоисправлено
**Ответ:** Добавлен `setup` сохраняет `@orig_io_select_writable`, `teardown` восстанавливает. Plan addendum D.
**Действие:** plan addendum D.

---

### SUGGESTION-4 — Комментарий про FIFO ordering guarantee

> minimax: объяснить почему Ruby Hash insertion-order даёт global FIFO.

**Источник:** minimax
**Статус:** Автоисправлено
**Ответ:** Добавлен комментарий-block над `drain_reads_all_clients` (plan addendum I).
**Действие:** plan addendum I.

---

### SUGGESTION-5 — `HELLO` тест-константа использует `MIN_PYTHON`

> deepseek: семантически точнее использовать CLIENT_VERSION.

**Источник:** deepseek
**Статус:** Отклонено
**Ответ:** Пока диапазон single-version (`MIN_PYTHON == MAX_PYTHON`) — без разницы. Future-proofing nice-to-have, но не критично. Отложено до момента, когда диапазон расширится.
**Действие:** none.

---

### SUGGESTION-6 — `handle_pre_handshake` валидация `request["id"]` для `id: null`

> deepseek: edge-case с `id: null` в pre-handshake-message.

**Источник:** deepseek
**Статус:** Отклонено
**Ответ:** JSON-RPC §5.1 явно допускает `"id": null` в error envelope для parse errors. Поведение по умолчанию (отвечаем с `id: null`) — допустимо и предсказуемо. Дополнительная валидация — overhead для edge case'а.
**Действие:** none.

---

### SUGGESTION-7 — `test_send_once_does_not_require_server_version_in_response` использует `"get_version"`

> deepseek: сбивает с толку (тест не про get_version).

**Источник:** deepseek
**Статус:** Автоисправлено
**Ответ:** В addendum G указано переименовать tool name на `"some_tool"`.
**Действие:** plan addendum G.

---

### SUGGESTION-8 — Logger DEBUG для `IO::WaitReadable`

> deepseek: помогло бы диагностике starvation.

**Источник:** deepseek
**Статус:** Отклонено
**Ответ:** На DEBUG это бы логировалось каждый тик для каждого клиента → spam. Diagnostics для starvation решаются другими путями (увеличить лог-detail вручную при необходимости).
**Действие:** none.

---

### QUESTION-1 — Post-handshake второй `hello`: `-32601` или close?

> codex: дизайн не уточняет.

**Источник:** codex
**Статус:** Обсуждено с пользователем (auto-decided)
**Ответ:** Выбран **Вариант A** — задокументировать `-32601` как нормальное поведение. Симметрия с любым другим неизвестным методом; никакого нового кода; код уже это делает. Добавлена явная фраза в design §6.2.
**Действие:** design §6.2.

---

### QUESTION-2 — Commit-by-commit e2e validity

**Статус:** Отклонено (см. CONCERN-14)

---

### QUESTION-3 — Accept-loop starvation: docs vs budget

**Статус:** Отклонено (реализуется в CONCERN-1 — добавлен ACCEPT_ABORTED_MAX)

---

### QUESTION-4 — `send_transport_error` с `request_id=nil` для framing error

**Статус:** Отклонено (JSON-RPC compliant — автор уже ответил)

---

### QUESTION-5 — Переименовать `test_server_compat.rb`?

**Источник:** deepseek
**Статус:** Обсуждено с пользователем
**Ответ:** Пользователь выбрал **Вариант A** — переименовать в `test/test_dispatch_post_handshake.rb`. Добавлены `git mv` step в Task 3, обновлены все ссылки в плане.
**Действие:** plan Task 3 step 1 + все ссылки (`ruby test/...`, `git add ...`, File Structure список).

---

### QUESTION-6 — Smoke `workloads = [LIGHT, HEAVY] * args.n` — мёртвый код

**Источник:** deepseek
**Статус:** Автоисправлено
**Ответ:** Удалена строка из plan Task 8 main(); цикл собирает per-iteration через `LIGHT_WORKLOAD if i == 0 else HEAVY_WORKLOAD` — `workloads` нигде не использовалась.
**Действие:** plan Task 8.

---

### QUESTION-7 — Cleanup `docs/superpowers/` mechanism

**Статус:** Отклонено (процедурный вопрос, не блокирует)

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-17-multi-client-server-design.md` | §4 (line 114 inventory), §5.1 (ClientState `close_after_response`), §5.3 (accept_pending_clients hardening, write_response framing rescue, framing-error discard semantics), §5.4 (close_client idempotency), §6.2 (post-handshake hello → -32601), §6.4 (Python connect timeout + error normalization) |
| `docs/superpowers/plans/2026-05-17-multi-client-server.md` | Task 3 (rename to test_dispatch_post_handshake.rb), Task 4 (close_client), Task 5 (step 3b/3c handshake envelope + write_response framing rescue + accessor; step 6 disconnect_mid_queue retrofit fix), Task 6 (step 4b/4c timeout + error normalization), Task 8 (HEAVY_WORKLOAD params, dead workloads), new Review Iteration 1 addenda A–J covering remaining concerns/suggestions |

## Статистика

- **Всего замечаний:** 38 (после дедупликации; 10 self-withdrawn в merged file не считаются)
- **Автоисправлено (без обсуждения):** 22
- **Авто-применено после анализа:** 2 (CONCERN-12, QUESTION-1)
- **Обсуждено с пользователем:** 1 (QUESTION-5)
- **Отклонено:** 11
- **Повторов (автоответ):** 0
- **Пользователь сказал "стоп":** Нет
- **Агенты:** codex-executor (gpt-5.5 xhigh), ccs-executor (glm), ollama-executor (minimax, deepseek). ollama-kimi не вернул output (watchdog stall).

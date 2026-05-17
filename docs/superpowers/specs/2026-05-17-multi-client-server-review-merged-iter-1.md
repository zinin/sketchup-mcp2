# Merged Design Review — Iteration 1

**Date:** 2026-05-17
**Topic:** multi-client-server
**Agents:** codex-executor, ccs-executor (glm), ollama-executor (minimax), ollama-executor (deepseek)
**Note:** ollama-kimi was launched but stalled in watchdog (event_count stuck at 30 for 9+ min, no output.txt). Excluded from merged set.

---

## codex-executor (gpt-5.5, xhigh reasoning)

### Critical Issues

- `hello` success response is built with `Handlers::Dispatch.build_success_response`, but that method wraps results into MCP `content` shape, not raw JSON-RPC result. Python `_handshake()` expects `result.server_version` directly, so the proposed Ruby code will fail the happy path. See [design:382](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:382), [plan:1529](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1529), and current [dispatch.rb:90](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/handlers/dispatch.rb:90). Build the handshake success envelope inline.

- Python `connect()` has no timeout around `_handshake()`. If Ruby accepts but never replies, `connect()` can hang indefinitely because the only `asyncio.wait_for(..., timeout=self.timeout)` remains in `_send_once`. See [design:514](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:514) and [plan:1970](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1970). `_handshake()` also lets `IncompleteReadError`/malformed error shapes escape as raw asyncio/AttributeError failures.

- Planned `write_response` does not handle `Framing.encode_frame` failures. Oversized response bodies raise `StructuredError` from framing, then `on_timer_tick` logs a server-level error and leaves the client connected but unanswered. That contradicts the per-client failure guarantee in [plan:7](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:7). See [plan:1551](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1551) and current [framing.rb:10](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/core/framing.rb:10).

- `close_client` returns before deleting from `@clients` when `state.closed?` is already true. Any externally/local-closed socket that reaches cleanup remains in `@clients` forever and is skipped on every tick. See [design:429](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:429) and [plan:1181](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1181). Delete from `@clients` regardless of closed status.

- Task 5 Step 6 corrupts the intended `disconnect_mid_queue` coverage. The design wants A1 processed, then A2/A3 skipped; the retrofit closes after the hello response and expects only `[0]`, so it no longer tests post-handshake queue skipping. See [design:740](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:740) and [plan:1667](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1667).

- The design promises `test_stale_socket_retry_redoes_handshake`, but the plan’s six Python tests do not include it. See [design:780](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:780) versus [plan:1833](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:1833) and [plan:2048](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:2048).

### Concerns

- FIFO tests do not actually prove cross-client ordering because each fake socket has an independent write buffer. Assertions like [plan:864](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:864) prove only per-socket response IDs, not global dispatch order.

- No planned test covers decoded-frame ordering across multiple ticks, partial frame completion, or “B decodes before A completes”. That is central to “FIFO by decoded arrival”.

- Framing-error delivery before close is under-tested. `test_framing_oversize_closes_only_that_client` checks closure and B’s response, but does not assert that A received the `-32600` envelope before close. See [plan:904](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:904).

- Mid-frame disconnect is not covered. EOF with no buffered partial frame is tested; EOF after header or partial body is a different state-machine case.

- `accept_pending_clients` is an unbounded loop. Under continuous connection churn it may never reach `IO::WaitReadable`, starving reads/dispatch for the tick. See [design:238](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:238).

- `setsockopt(SO_KEEPALIVE)` happens after accept but before `ClientState` registration. If it raises, the accepted socket is not closed and not tracked. See [plan:2136](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-05-17-multi-client-server.md:2136).

- The design says decoded frames before a framing error in the same chunk enter `@frame_queue`, but current `FrameReader#feed` returns only after the whole loop finishes; if it raises later, earlier completed bodies are lost. See [design:297](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:297) and [framing.rb:26](/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp/core/framing.rb:26).

- Design line [design:114](/opt/github/zinin/sketchup-mcp2/docs/superpowers/specs/2026-05-17-multi-client-server-design.md:114) says `Dispatch` accepts `ClientState`, but later sections and the session decision say handlers do not get `ClientState`. This should be corrected.

- Plan omits `src/sketchup_mcp/tools.py` updates, despite the design saying `get_version` wording must stop describing bypass semantics. Current comments still describe the old bypass path at [tools.py:455](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/tools.py:455) and [tools.py:482](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/tools.py:482).

### Suggestions

- Add a raw JSON-RPC helper for handshake success, or inline the hash: `{"jsonrpc"=>"2.0", "result"=>{"server_version"=>..., "client_id"=>...}, "id"=>...}`.

- Wrap `_handshake()` in `asyncio.wait_for(..., timeout=self.timeout)` and normalize timeout, EOF, connection reset, malformed JSON, malformed error/result, and id mismatch into `SketchUpError`/`IncompatibleVersionError`.

- Harden `write_response` so response oversize cannot become a server-level swallowed error. Either send a small `-32603 response too large` fallback once, or close that client with a clear log if even the fallback cannot be encoded.

- Make `close_client` idempotent but always remove the state from `@clients`; `closed?` should only decide whether to call `sock.close`.

- Improve fakes before relying on coverage: make `FakeSocket#read_nonblock(n)` respect `n`, add configurable write timeout/write failure, and add a shared write-event log for cross-client ordering assertions.

- Add focused tests for: handshake write timeout, framing error envelope before close, partial-frame EOF, global FIFO across sockets, multi-tick decode order, stale-socket retry re-handshakes, and `@close_after_response` with pipelined frames after a rejected hello.

### Questions

- Should a post-handshake second `hello` be treated as ordinary `-32601` and keep the socket open, or as a protocol violation that closes the client?

- Do you want commit-by-commit e2e to remain valid? As written, the Task 5 commit intentionally breaks Python↔Ruby e2e until Task 6.

- For accept-loop starvation, do you want only documentation of the accepted risk, or a defensive per-tick accept budget that defers extra accepts without imposing a hard concurrent-client cap?
---

## ccs-executor (glm — GLM-5.1)

Все документы и исходный код прочитаны. Перехожу к составлению ревью.

---

# Ревью: Multi-client Ruby TCP Server + One-time Handshake

Прочитал оба документа полностью (design ~917 строк, plan ~2580 строк), сопоставил с текущим кодом `server.rb`, `dispatch.rb`, `connection.py`, `compat.rb`, `framing.rb`, `errors.rb`, `compat.py`.

---

### Critical Issues

**1. `drain_one_client` — чтение «вслепую» после framing error нарушает протокол**

Design §5.3 (`drain_one_client`) и Plan Task 4 Step 4 (строки ~1083–1104): при `StructuredError` от `FrameReader#feed` (zero-length / oversize frame) сервер вызывает `send_transport_error`, затем `close_client`. Но **прежде** чем `close_client` успеет отработать, `state.reader.feed(chunk).each` уже мог вернуть 0+ декодированных body из этой же порции данных — и все они попали в `@frame_queue`. Проблема: `FrameReader` имеет **внутренний буфер** и state machine (`@state = :reading_header / :reading_body`). Framing error (`validate_length!`) поднимает `StructuredError` *после* чтения заголовка, но **до** чтения body. В этот момент `@buffer` обрезан на 4 байта (длина удалена), а `@expected_length` хранит невалидное значение. `close_client` закрывает сокет, но `@frame_queue` уже содержит stale-фреймы. Они будут пропущены при `state.closed?`, так что это не crash, но логика показывает, что `feed` не может вернуть частичные результаты до поднятия ошибки: `feed` — atomic (цикл `loop do ... end` внутри), error пробрасывается наружу, уже декодированные тела были возвращены *до* ошибки через `completed << body`. Т.е. корректных body из того же chunk'а не появится. Это в порядке. Отзываю это замечание.

**2. `@close_after_response` race: handshake rejection + write timeout**

Design §5.3 (`write_response`, строки ~401–418) и Plan Task 5 Step 3c (строки ~1551–1567):

```ruby
def write_response(state, response)
  ...
  unless io_select_writable?(state.sock)
    close_client(state, "write_timeout")
    return
  end
  state.sock.write(frame)
  state.sock.flush
  if state.instance_variable_get(:@close_after_response)
    close_client(state, "handshake_rejected")
  end
rescue Errno::EPIPE, Errno::ECONNRESET, IOError
  close_client(state, "write_failed")
end
```

Если `io_select_writable?` возвращает `false` (write timeout), вызывается `close_client(state, "write_timeout")`, метод выходит через `return`. Но `@close_after_response` при этом не сбрасывается. Это не баг (клиент уже закрыт), но **есть тонкость**: в `close_client` мы делаем `@clients.delete(state.sock)`. Если где-то в том же tick'е после `write_response` по ошибке произойдёт второй вызов `close_client` с тем же state — `state.closed?` вернёт `true`, и метод сделает early return. Защита есть.

Однако более серьёзная проблема: **если `io_select_writable?` возвращает `true`, но `write` поднимает `Errno::EPIPE`**, управление уходит в rescue, `close_client` вызывается, но `@close_after_response` **не проверяется** — что OK, клиент уже закрыт. Но если `flush` падает — то же. В целом путь корректен.

**Реальная критическая проблема**: `@close_after_response` — это instance variable на `ClientState`, которая не объявлена в `ClientState` (`attr_accessor` для неё нет). Она выставляется через `state.instance_variable_set(:@close_after_response, true)` и читается через `instance_variable_get`. Если по какой-то причине `close_client` вызывается *до* `write_response` (например, из параллельного пути в `drain_one_client`), флаг останется установленным, и следующая попытка записи уже закрытому клиенту попытается закрыть его снова. Guard `state.closed?` в `close_client` спасает от double-close.

**Вердикт**: Работает, но хрупко. См. Suggestions.

**3. `handle_frame` rescue: parse error теряет `request_id` из тела с ошибкой парсинга**

Design §5.3 (`handle_frame`, строки ~315–344):

```ruby
rescue JSON::ParserError => e
  ...
  send_transport_error(state, Core::StructuredError.new(-32700, ...), nil)
  close_client(state, "parse_error")
```

Передаётся `request_id = nil`. По JSON-RPC §5.1 это корректно для parse error («id should be null»). OK.

Но другая ветка:
```ruby
rescue StandardError => e
  ...
  rid = request.is_a?(Hash) ? request["id"] : nil
```

Если `JSON.parse` успел вернуть не-Hash (например, `"hello"` — массив или скаляр), то `request` — не Hash, `rid = nil`. Это корректно — defensive — но **вопрос**: что если `request` — это Hash, но без `"id"` (notification)? В `handle_frame` это не перехватывается как notification, потому что проверка `is_notification` стоит только для pre-handshake. Для post-handshake `Dispatch.handle` возвращает `nil`, и `write_response` не вызывается. OK.

**Но**: если `Handlers::Dispatch.handle` сам поднимает `StandardError` (не `StructuredError`), то rescue вернёт error response с `rid = request["id"]`. Если `request` — notification (без `"id"`), `rid = nil`, и error response будет отправлен. Это нарушение JSON-RPC §4.1. Проверю `Dispatch.handle`: там есть `return nil if is_notification` в rescue `StructuredError` и `StandardError`. Но `is_notification` вычисляется **внутри** `Dispatch.handle`, не в `handle_frame`. В `handle_frame`'s rescue `StandardError` после успешного `JSON.parse` — `request` уже валидный Hash, и если `Dispatch.handle` выкинул что-то за пределами своего rescue (невозможно, потому что Dispatch обёрнут), или если код после `Dispatch.handle` выкинул — например, `write_response` не вызывается внутри `handle_frame`, он вызывается в `process_frame_queue`. Так что rescue `StandardError` в `handle_frame` ловит только ошибки *до* возврата из `Dispatch.handle`. Изучите Task 4 Step 4 код — `handle_frame` делает `JSON.parse(body)` и `Handlers::Dispatch.handle(request)`. `Dispatch.handle` имеет свой rescue. Поэтому rescue `StandardError` в `handle_frame` — это defensive catch-all для совершенно неожиданных ситуаций (например, `NoMethodError` из-за бага).

**4. `accept_pending_clients`: потенциально бесконечный loop**

Design §5.3 и Plan Task 4 (строки ~1058–1073):

```ruby
def accept_pending_clients
  loop do
    begin
      sock = @server.accept_nonblock
    rescue IO::WaitReadable
      return
    rescue Errno::ECONNABORTED
      next   # transient on Windows
    end
    ...
  end
end
```

Если на Windows (или под Wine) `Errno::ECONNABORTED` поднимается повторно для каждого вызова `accept_nonblock` (например, ядро держит aborted connection в backlog), loop никогда не завершится — будет бесконечный `next`. Это **реальная проблема**: таймер tick заблокирует UI поток SketchUp. Нужен счётчик `ECONNABORTED` или fallback `return` после N повторных `ECONNABORTED`.

**5. `process_frame_queue` и cross-tick frame ordering**

Design обещает FIFO по arrival order. Но в Plan Task 4, `drain_reads_all_clients` делает snapshot `@clients.values` (строка ~1077). Если во время итерации `drain_one_client` одного клиента в очередь попал фрейм, а клиент B ещё не обработан (итерация до него не дошла), порядок в `@frame_queue` определяется порядком итерации по snapshot. Ruby Hash в 1.9+ сохраняет insertion order. `@clients` — это `{sock => ClientState}`. Порядок итерации — порядок accept'а. Это FIFO по accept time, не по TCP arrival time. Design §5.3 говорит: «Frames are processed in the order they fully decode into the server's queue — single shared queue, not per client». Это именно то, что реализовано. Принято.

**6. Task 5 Step 6: Retrofit Task 4 tests — риск ошибки при массовой правке**

Plan Task 5 Step 6 (строки ~1606–1678) требует ручного обновления всех тестов из `test_server_multi_client.rb`: к каждому `read_chunks` добавить `HELLO`, обновить assertions. Это 10 тестов, каждый с разной структурой. При этом текст плана содержит **ошибку** в строке ~1676:

> (Wait — re-read the test. ... So only `[0]` makes it out. Update accordingly: `assert_equal [0], ...`)

Это замечание в скобках — автор сам заметил противоречие и не решил его окончательно. Для агента, исполняющего план, это будет неоднозначность. Нужен однозначный expected.

**7. `send_transport_error` в `handle_frame` — ошибка отправки после framing error**

Plan Task 4 (строки ~1100–1104):

```ruby
rescue StructuredError => e
  send_transport_error(state, e, nil)
  close_client(state, "framing_error: #{e.message}")
```

`send_transport_error` вызывает `write_response`, который делает `io_select_writable?` + `write`. Если клиент уже закрыл соединение (что типично при framing error — half-open), `write` поднимет `Errno::EPIPE`, который ловится в `write_response` и вызывает `close_client`. Затем `close_client` вызывается *снова* в `drain_one_client`. Guard `state.closed?` спасает, но лог будет содержать **два** `client_disconnected` сообщения для одного и того же клиента (одно из `write_response` rescue, другое из `drain_one_client`). Это может запутать при диагностике.

---

### Concerns

**C1. FakeSocket не эмулирует `IO.select`**

Test helper `FakeSocket` (Plan Task 4 Step 1) не реализует behaviour, совместимое с `IO.select`. План решает это через monkey-patching `io_select_writable?` (Plan Task 4 Step 2, строка ~788). Но этот monkey-patch — `class_eval` на `SU_MCP::Core::Server` — **глобальный** для всех тестов в процессе. Если тесты запускаются через `test/run_all.rb`, monkey-patch из одного тест-файла протечёт в другой. Minitest запускает тесты в одном процессе.

Решение: каждый тест делает `class_eval` в `setup`, и это перезаписывает метод. Но **нет cleanup** в `teardown` — оригинальный метод не восстанавливается. Если после тестов multi_client запускается test_server_compat.rb, и тот использует реальный `Server`, monkey-patched `io_select_writable?` вернёт `true` всегда. Это может замаскировать реальные проблемы в других тестах.

**C2. `_handshake()` timeout не покрывается**

Design §6.4 и Plan Task 6 Step 4c: `_handshake()` делает `self._recv_frame()` без собственного timeout. `_recv_frame()` использует `self._reader.readexactly()`, который заблокирует до бесконечности, если Ruby не ответит. В `_send_once` есть `asyncio.wait_for(..., timeout=self.timeout)`, но `_handshake` **не обёрнут** в `wait_for`. Если Ruby молчит (зависла, не стартовала), Python-клиент повиснет навсегда.

Нужно: `response_body = await asyncio.wait_for(self._recv_frame(), timeout=self.timeout)`.

**C3. Python `_handshake` не обрабатывает `server_version = None`**

Plan Task 6 Step 4c (строки ~2014–2018):

```python
server_version = result.get("server_version")
self._server_version = server_version
self._client_id = result.get("client_id")
compat.check_ruby_version(server_version)
```

`server_version` может быть `None` (если Ruby не включил его в result). `compat.check_ruby_version(None)` поднимет `IncompatibleVersionError` с сообщением «pre-dates version-compat checking». Это корректно. OK.

**C4. Plan Task 4 commit break e2e**

Plan Task 4 (multi-client server without handshake) оставляет систему в промежуточном состоянии: Ruby не проверяет `client_version` (Task 3 убрал из Dispatch), но ещё не требует `hello` (Task 5 не начат). Python всё ещё шлёт `client_version` в каждом запросе (Task 6 не начат). В этом состоянии `client_version` — просто лишнее поле в JSON, Ruby его игнорирует. E2e продолжает работать. OK, план это признаёт (строка ~629–631).

**C5. Plan Task 5 Step 6 retrofits Task 4 tests — instruction precision**

Для каждого из 10 тестов Plan даёт фрагменты кода (строки ~1613–1678), но некоторые указания неполные:
- `test_eof_on_one_client_does_not_close_others`: указано обновить B, но не указано, что делать с A (A не получает hello — EOF поднимается первым, что корректно, но не упомянуто).
- `test_framing_oversize_closes_only_that_client`: «same as parse-error case» — отсылка к другому тесту, но exact diff не показан.

Для агента это источник возможных ошибок.

**C6. `encode_response_body` fallback в Task 5 не инжектирует `server_version`**

Plan Task 5 Step 3d (строки ~1573–1583): fallback envelope при `JSON::GeneratorError` не включает `server_version`. В Task 4 Step 4 (строки ~1155–1167) fallback включал `server_version`. После Task 5 это удалено, потому что handshake уже вернул версию. Но если fallback envelope отправляется клиенту, который ещё не handshake'нулся (pre-handshake parse error path), он не получит версию. Это OK, потому что pre-handshake ошибки ведут к close.

**C7. `test_server_multi_client.rb` helper functions `fr` и `all_frames` дублированы**

В `test_server_multi_client.rb` и `test_server_handshake.rb` определены одни и те же функции `fr` и `all_frames` как module-level. При запуске через `test/run_all.rb` оба файла загрузятся, и второе определение перезапишет первое. Функции идентичны, так что это не баг, но нарушение DRY.

---

### Suggestions

**S1. Заменить `@close_after_response` shim на bool accessor в `ClientState`**

Вместо `state.instance_variable_set(:@close_after_response, true)` и `state.instance_variable_get(:@close_after_response)` добавьте `attr_accessor :close_after_response` в `ClientState` (Task 1). Это стоит одной строки, но устраняет хрупкость и улучшает читаемость. Design §13.3 признаёт, что shim — временный, но с одним известным использованием accessor ничем не хуже ivar shim.

**S2. Ограничить `ECONNABORTED` loop в `accept_pending_clients`**

Добавьте счётчик:
```ruby
aborted = 0
loop do
  begin
    sock = @server.accept_nonblock
    aborted = 0
  rescue IO::WaitReadable
    return
  rescue Errno::ECONNABORTED
    aborted += 1
    return if aborted > 10
    next
  end
  ...
end
```

**S3. Обернуть `_handshake()` в `asyncio.wait_for`**

```python
async def connect(self) -> None:
    self._reader, self._writer = await asyncio.open_connection(...)
    try:
        await asyncio.wait_for(self._handshake(), timeout=self.timeout)
    except asyncio.TimeoutError:
        await self.disconnect()
        raise SketchUpError(-32000, f"handshake timed out after {self.timeout}s") from None
    except Exception:
        await self.disconnect()
        raise
```

**S4. Восстанавливать `io_select_writable?` в teardown тестов**

```ruby
def teardown
  SU_MCP::Core::Server.class_eval do
    def io_select_writable?(sock)
      IO.select(nil, [sock], nil, WRITE_SELECT_TIMEOUT_S)
    end
  end
end
```

Или вынести stub в `run_one_tick` через `ensure`.

**S5. Вынести `fr` и `all_frames` в `test/support/`**

Создайте `test/support/frame_helpers.rb` с `fr` и `all_frames`, подключайте через `require_relative`.

---

### Questions

**Q1. `handle_frame` post-handshake: если `Dispatch.handle` возвращает `nil` (notification), но `process_frame_queue` уже прошёл проверку `state.closed?`, может ли клиент быть закрыт *внутри* `Dispatch.handle`?**

`Dispatch.handle` не имеет доступа к `ClientState` и не может закрыть клиент. Но если `Dispatch.handle` вызывает handler (например, `eval_ruby`), который как-то влияет на сокет... нет, handlers не имеют доступа к сокету. Ответ: нет, не может.

**Q2. Будет ли `_RETRY_SAFE_TOOLS` на Python стороне по-прежнему корректен после handshake?**

Да. `_RETRY_SAFE_TOOLS` — это whitelist для retry при `_StaleSocketError`. Retry вызывает `_send_once`, который вызывает `_connect_or_raise` → `connect()` → `_handshake()`. Так что re-handshake происходит автоматически. OK.

**Q3. Почему `encode_response_body` в Task 4 (pre-handshake) инжектирует `server_version`, но в Task 5 (post-handshake) — нет, при этом parse-error path в `handle_frame` тоже использует `encode_response_body`?**

Parse error path в `handle_frame` вызывает `send_transport_error` → `write_response` → `encode_response_body`. В Task 5 `encode_response_body` не инжектирует `server_version`. Parse error client будет закрыт, так что отсутствие `server_version` в error envelope — OK. Но если по какой-то причине parse error происходит у handshaked-клиента, error response уйдёт без `server_version`. Это не проблема — handshake уже сообщил версию. OK.

**Q4. Plan Task 10 Step 8: «Design + plan will be removed in the PR-finishing step» — как именно?**

Глобальный CLAUDE.md говорит: «Before creating a PR: `git rm` all files from `docs/superpowers/` and commit». Но план упоминает «superpowers:finishing-a-development-branch skill». Уточните: будет ли использован skill для этого шага?

---

**Резюме**: Документы детальны и хорошо проработаны. Главное, что нужно исправить до реализации: (1) добавить guard на `ECONNABORTED` loop, (2) обернуть `_handshake()` в `wait_for` на Python стороне, (3) устранить неоднозначность в Task 5 Step 6 (retrofit test assertions), (4) заменить ivar shim на accessor. Остальное — рабочее и последовательное.

---

## ollama-executor (minimax — MiniMax M2.7 cloud)



Теперь у меня есть полное представление о коде, дизайне и плане. Провожу критический анализ.

---

## Critical Issues

### 1. `send_transport_error` — ранний возврат без закрытия клиента

**Дизайн §5.3 / Task 4, `send_transport_error`:**

```ruby
def send_transport_error(state, structured_error, request_id)
  return if state.closed?
  response = Errors.build_error_response(...)
  write_response(state, response)
rescue StandardError => e
  Logger.log_error("server.send_transport_error", e, client_label: state.label)
end
```

Проблема: если `state.closed?` стал `true` **между** моментом когда `drain_one_client` вызвал `send_transport_error` и моментом когда он сам вызывает `close_client`, то `send_transport_error` делает ранний `return` — ответ не отправляется. `close_client` от `drain_one_client` выполняется, клиент закрывается. Клиент **не получает** `-32700` error envelope. Это несоответствие: RFC 7800 требует чтобы framing error result в ошибке транспорта до закрытия соединения.

Корректное поведение: отправить ответ **до** закрытия, или гарантировать что ранний возврат не происходит. С учётом того что `drain_one_client` всегда вызывает `close_client` после `send_transport_error`, ранний возврат оставляет клиента без final response.

**Рекомендация**: убрать `return if state.closed?` из `send_transport_error` — пусть write попытается выполниться; если сокет уже закрыт, `write_response` сам закроет клиент через `EPIPE`/`ECONNRESET`.

---

### 2. `compat.py` / `compat.rb` — версии жёстко закодированы как `"0.0.3"`

Обе стороны:

- Ruby: `SERVER_VERSION = "0.0.3"`, `MIN_PYTHON = MAX_PYTHON = "0.0.3"`
- Python: `MIN_RUBY = MAX_RUBY = "0.0.3"`, `CLIENT_VERSION` импортируется из `__version__`

Ветка `feature/multi-client-server` — это **следующий** релиз после 0.1.0. Версии в коде не обновлены. Это не блокирующая проблема для ревью дизайна, но в плане нет шага по обновлению версий (он происходит в `docs/release.md` как часть процесса релиза), и это создаёт риск что перед мержем придётся править не только дизайн.

---

### 3. Промежуточное состояние Task 4 → Task 5 нарушает end-to-end

**План Task 4-commit**: Ruby сервер принимает любые фреймы без handshake, Python клиент **не** отправляет `hello`, но отправляет `client_version` в каждом запросе. Python клиент **не** получает `server_version` (Task 4 убирает инъекцию из `encode_response_body`).

**План Task 4, шаг 5**: `encode_response_body` **оставляет** `server_version` инъекцию. Так что после Task 4 всё ещё есть `server_version` в ответах, Python проверяет версию в каждом ответе — e2e работает.

Но после **Task 5** (добавление handshake gate): `encode_response_body` **убирает** `server_version` инъекцию. Python (ещё не обновлённый) не получает `server_version` в большинстве ответов, и Python-side `check_ruby_version` падает. **Единственный** обход — `get_version` имеет bypass, поэтому `get_version` работает, но все остальные工具 падают.

Это **документировано** в плане (Task 5: "Task 5 commit briefly breaks e2e") и принято как допустимое для feature-ветки. Тем не менее, это хрупкое состояние: если кто-то запустит `smoke_check.py` между Task 5 и Task 6, увидит ошибки.

---

## Concerns

### 4. `@close_after_response` — хрупкий shim

Дизайн (§13.3) сам признаёт что это shim. Проблема в том что флаг устанавливается через `instance_variable_set` на объекте `ClientState`, а проверяется в `write_response` **после** успешного write. Если write падает в `rescue` (EPIPE/ECONNRESET/IOError), `close_client` вызывается в rescue-ветке — флаг `@close_after_response` **не проверяется**. Это корректно (close всё равно нужен), но семантика "respond-then-close" хрупкая: если позже появится ещё один сайт с такой логикой, забыть проверить флаг после write будет легко.

Связанная проблема: `close_client` в rescue-ветке `write_response` вызывается **без** причины `"handshake_rejected"` — при write failure причина другая (`"write_failed"`). Это разумно, но не документировано.

### 5. Нет теста на framing error response delivery

В плане (Task 4, тест 10) проверяется что framing error (oversize frame) закрывает клиента B, но **не** проверяется что клиент A получил transport error envelope (-32600) перед закрытием. Тест 10 проверяет только что `a.closed?` и `b.closed?`, но не проверяет содержимое `a.written`.

Аналогично, в Task 5 (test 14: pre_handshake_notification) проверяется что `sock.closed?` и `sock.written` пуст, но нет теста где framing error (StructuredError) отправляет `-32600` клиенту.

### 6. `test_post_handshake_response_has_no_server_version_field` — тест проверяет следствие, а не причину

Тест проверяет `refute frames[1].key?("server_version")` в post-handshake ответе. Но он **не** проверяет что handshake-ответ **содержит** `server_version` в `result`. Если по ошибке `server_version` убран из handshake-ответа, тест всё равно пройдёт — он проверяет только что простой ответ не содержит поле, а не что handshake-ответ его содержит.

### 7. `test_server_level_error_in_tick_does_not_reset_clients` — сомнительный тест

Этот тест в Task 4 создаёт `FakeServer` с `accept_nonblock` который всегда поднимает `StandardError`, подсовывает **существующий** `ClientState` в `@clients`, и проверяет что после `on_timer_tick` клиент не closed и остался в `@clients`.

Проблема: тест не запускает tick **полностью** — он только проверяет что top-level `rescue` в `on_timer_tick` не сбрасывает клиентов. Но он не проверяет что `accept_pending_clients` не выбросил наружу (потому что `accept_nonblock` поднял ошибку **до** того как `loop` вызвал `next` или `return`). Этот тест не покрывает реальный сценарий: когда `accept_nonblock` поднимает ошибку **после** успешного accept-а (например, `setsockopt` падает), существующие клиенты должны остаться.

### 8. Plan: отсутствует тест на `write_response` EPIPE после `@close_after_response`

Plan Task 5 не включает тест: "если `@close_after_response` установлен, но write падает с EPIPE — клиент всё равно закрывается (через rescue-ветку)". Это важно потому что rescue-ветка **не** проверяет флаг.

### 9. SO_KEEPALIVE на Windows

Дизайн (§13.2) упоминает что `SO_KEEPALIVE` работает на Windows, но `TCP_KEEPIDLE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT` доступны только на Linux. Текущий код использует только `SO_KEEPALIVE` (без дополнительных `setsockopt`), так что это корректно для обеих платформ. Однако Windows default для `tcp_keepalive_time` — 2 часа (та же проблема что на Linux), и нет способа это уменьшить без `SIO_KEEPALIVE_VALS`. Это **документировано** в дизайне, но стоит убедиться что пользователь это понимает.

### 10. Plan: несоответствие между Task 4 Step 6 и Task 5 Step 6

Plan Task 4 говорит "все multi-client тесты требуют hello prepend". Task 5 Step 6 даёт конкретные assertion updates. Но Step 6 в Task 5 говорит что тесты "still need a hello prepended" — как будто Task 4 уже обновил тесты. На самом деле Task 5 **обновляет** тесты из Task 4. Это описано в Task 5 Step 6, но Step 2 в Task 5 просто говорит "Run the new tests and verify they fail". Нет отдельного шага где тесты Task 4 явно обновляются перед тем как Step 7 запускает их. Это скорее ambiguity в плане, но итоговый результат корректен.

---

## Suggestions

### 11. Добавить явный тест `@close_after_response` + write failure

Тест: hello rejection → server write response → **закрыть FakeSocket на стороне клиента** (имитировать то что клиент закрыл сокет до получения ответа) → проверить что клиент закрыт, ответ записан. Текущие тесты проверяют только happy path для `@close_after_response`.

### 12. `send_transport_error` — документировать early-return семантику или убрать guard

Guard `return if state.closed?` делает поведение неочевидным. Либо задокументировать "если клиент уже закрыт — ошибка не отправляется, close_client вызывается отдельно", либо убрать guard и полагаться на `write_response` который сам закроет.

### 13. В тесте `test_post_handshake_response_has_no_server_version_field` добавить assertion для handshake-ответа

```ruby
assert_equal SU_MCP::Core::Compat::SERVER_VERSION, frames[0]["result"]["server_version"]
```

Это гарантирует что `server_version` **появляется** в handshake response, а не просто отсутствует в последующих.

### 14. Добавить assertion что framing error отправляет -32600 envelope

В Task 4, тест `test_framing_oversize_closes_only_that_client` проверяет что B получает ответ с id=9, но не проверяет что A получил `-32600` framing error envelope. Связанный тест `test_parse_error_on_one_client_closes_only_that_client` проверяет `frames_a[0]["error"]["code"] == -32700` — аналогичная проверка для framing была бы уместна.

### 15. `process_frame_queue` — добавить комментарий о queue ordering guarantee

Когда `@frame_queue` обрабатывается через `shift`, порядок FIFO гарантируется. Но `@frame_queue` заполняется из нескольких `drain_one_client` вызовов в одном tick. Комментарий в коде объясняющий почему это даёт глобальный FIFO (а не per-client) был бы полезен:

```ruby
# Frames are pushed in the order drain_one_client visits each client.
# Within one client, chunks are consumed in order (serial socket reads).
# Across clients, Hash#values iteration order is deterministic in Ruby 2.x
# (insertion-ordered since Ruby 3.0+, but even if not — FIFO across
# clients is a best-effort property, not a hard guarantee per design §3).
@clients.values.each do |state|
  drain_one_client(state)
end
```

### 16. Plan: уточнить порядок между Task 3 и Task 4 для `test_server_compat.rb`

Plan Task 3 говорит "rewrite test_server_compat.rb → drop version cases, add post-handshake dispatch cases". Но Task 3 commit **убирает** version check из `Dispatch`. Task 4 commit **добавляет** multi-client server. Если запустить `ruby test/run_all.rb` **после** Task 3 (но до Task 4), старые тесты которые зависят от version-per-request упадут. Plan не говорит что делать с этими тестами между Task 3 и Task 4. (Task 3 Step 2 говорит "most tests fail" — это ожидаемо, но не указано что старые тесты нужно удалить или закомментировать.)

---

## Questions

### Q1. Почему `encode_response_body` после Task 5 не инжектирует `server_version` вообще?

После Task 5, `encode_response_body` просто делает `JSON.generate(response)` без инъекции `server_version`. Это означает:
- `get_version` tool handler возвращает версию внутри `result` (через `Handlers::System.get_version`)
- Но **顶层** response от `build_success_response` не получает `server_version`

Это диктуется дизайном (§6.2: "no `server_version` field"). Корректно ли я понимаю что `get_version` tool теперь **не** должен добавлять `server_version` в свой ответ? Или `Handlers::System.get_version` должен добавлять `server_version`顶层 вручную?

### Q2. Что происходит если Ruby `check_python_version` выбрасывает `StructuredError` во время `handle_pre_handshake`, но `reject_handshake` сам вызывает `build_error_response`?

В `handle_pre_handshake`:
```ruby
begin
  Core::Compat.check_python_version(params["client_version"])
rescue StructuredError => e
  return reject_handshake(state, request, e)
end
```
Это покрывает версию. Но что если `reject_handshake` сам выбрасывает? `reject_handshake` вызывает `Errors.build_error_response` который может выбросить, например, `JSON::GeneratorError`. Этот exception поднимется наверх через `handle_pre_handshake` → `handle_frame` → `process_frame_queue`. Ни один из этих методов не ловит `JSON::GeneratorError`. Он попадёт в `rescue StandardError => e` в `handle_frame`? Нет, `JSON::GeneratorError` — подкласс `StandardError`, так что да, попадёт, и будет возвращён как -32603 error response. Это **может** оставить клиента открытым (потому что `close_client` не вызывается в StandardError path). Это приемлемо? Я думаю да, потому что `build_error_response` скорее всего не упадёт для обычных error objects. Но стоит документировать это как known limitation или добавить defensive wrap.

### Q3. Какой порядок клиентов в `@clients` при итерации?

`@clients` — это `Hash`. В Ruby 3.x хэши сохраняют порядок вставки. Клиенты добавляются через `@clients[sock] = state` в `accept_pending_clients`. Порядок определяется порядком вызовов `accept_nonblock` — то есть порядком подключения клиентов. Это приемлемо для дизайна (§3: "FIFO by decoded-frame arrival"), но стоит задокументировать что порядок не является "fair" — он следует порядку подключения, а не порядку arrivals данных. И если два клиента одновременно подключаются, порядок определяется ядром (не детерминирован для параллельных подключений). Дизайн §13.1 об этом не говорит.

### Q4. Есть ли race condition между `close_client` и `drain_reads_all_clients`?

`snapshot — clients may be modified mid-iteration on errors` комментарий в `drain_reads_all_clients`. `@clients.values.each` — это snapshot. Но `@frame_queue` модифицируется параллельно с итерацией. Если `close_client` вызывается из `drain_one_client`, `@clients` уменьшается, но итерация по snapshot не затрагивается. Однако `@frame_queue` пополняется из каждого `drain_one_client`. Если клиент A закрывается в середине своей итерации, его оставшиеся фреймы (которые ещё не декодированы) никогда не попадут в `@frame_queue` — они останутся в `state.reader` буфере. Это означает что close mid-drain теряет непрочитанные данные. Это приемлемо? Да, потому что клиент уже close, и попытка доставить оставшиеся данные бессмысленна. Но стоит это задокументировать.

---

## ollama-executor (deepseek — DeepSeek-V4 Pro cloud)

Теперь у меня есть полная картина. Давайте дам разбор.

---

# Рецензия: Multi-client Ruby TCP server + one-time handshake

## Critical Issues

### 1. `_handshake()` в Python не имеет таймаута — Design §6.4 / Plan Task 6 Step 4c

**Plan**, строка 1984–2019: `_handshake()` вызывает `self._recv_frame()` без `asyncio.wait_for`. Если Ruby-сервер принял TCP-соединение, но завис до отправки handshake-ответа (например, SketchUp frozen), Python-клиент блокируется навсегда. Для сравнения: `_send_once` (plan строка 2030+) оборачивает `_roundtrip` в `asyncio.wait_for(..., timeout=self.timeout)`.

`connect()` в плане (строка 1969–1978) использует `asyncio.open_connection` без таймаута на установление TCP-соединения — существующая проблема, но с `_handshake()` она усугубляется: даже после успешного TCP-connect клиент может повиснуть.

**Design §6.4** тоже не упоминает таймаут для `_handshake`.

### 2. Smoke test: `boolean_operation` использует несуществующие параметры `target_name`/`tool_name`

**Plan**, строки 2259–2262:
```python
{"tool": "boolean_operation",
 "args": {"operation": "union",
          "target_name": "smoke_box_heavy_A",
          "tool_name":   "smoke_box_heavy_B"}},
```

Фактические параметры `boolean_operation` — `target_id` и `tool_id`. MCP-тул ожидает entity ID (строка), а не name. Дымовой тест упадёт с `-32602` (invalid params) при первом же запуске. Нужно либо использовать `target_id`/`tool_id` с предварительным `find_components` для получения ID, либо переписать логику на `eval_ruby`.

### 3. Design §10.1 обещает 14 тест-кейсов, но план пропускает два из них

**Design §10.1** перечисляет 14 случаев. **Plan** покрывает 12:

- **Кейс 9 (Write timeout one client):** план говорит в `setup` про "Always-ready writes; per-test override when testing write_timeout" (строка 776), но ни один тест не переопределяет `io_select_writable?` для возврата `nil`. Тест на write-timeout изоляцию отсутствует.
- **Кейс 12 (No idle-deadline path exists):** ни в `test_server_multi_client.rb`, ни в `test_server_handshake.rb` нет теста, проверяющего, что клиент НЕ закрывается при длительном отсутствии фреймов. Design обещает "assert by sending zero frames for a long simulated time and showing client is NOT closed".

Это не критические пробелы в функциональности (write-timeout редко случается в практике; idle-deadline действительно удалён), но это inconsistency между спецификацией и планом.

## Concerns

### 4. `Accept_pending_clients` в плане Task 4 не выставляет `SO_KEEPALIVE` — окно без half-open detection

**Plan**, строки 1058–1073: `accept_pending_clients` создаёт `ClientState`, но `setsockopt(SO_KEEPALIVE)` добавляется только в Task 7. Между коммитами Task 4 и Task 7 клиенты беззащитны против half-open сокетов. Поскольку ветка немёрженая и разработчик один, это приемлемо, но стоит упомянуть явно. План говорит об этом только для `IDLE_DEADLINE_S` ("that was already accomplished in Task 4 because we never re-added the constant"), но не для `SO_KEEPALIVE`.

### 5. `send_transport_error` + `close_client` — возможна потеря framing-error ответа

**Plan**, строки 1096–1103 (Task 4), и строки 1466–1491 (Task 5). При `StructuredError` из `FrameReader` (zero-length/oversize) вызывается `send_transport_error`, затем `close_client`. `send_transport_error` делает `write_response`, который пишет фрейм через `io_select_writable?` → `write` → `flush`. Если `write_response` выбросит `EPIPE`/`ECONNRESET` (клиент уже отвалился), `close_client` внутри `write_response` уже закрыл сокет. Повторный `close_client` в `drain_one_client` проходит без вреда (check `state.closed?`).

Но если `io_select_writable?` вернёт `nil` (write timeout), `write_response` закроет клиента с `reason="write_timeout"`. Затем `drain_one_client` вызовет `close_client(state, "framing_error: ...")` — но `state` уже закрыт, так что `close_client` просто выйдет. Причина в логе будет "write_timeout", а не "framing_error". Это минорный баг в логгировании, не влияет на корректность.

### 6. `test_connect_sends_hello_first_with_client_version` — гонка на чтении `fs.received`

**Plan**, строки 1863–1878. Тест делает `await asyncio.sleep(0.05)` перед чтением `fs.received`. `FakeServer._handle` пишет ответ, затем входит в `reader.read()` — цикл чтения клиентских данных. Клиент в это время уже прочитал ответ и вызвал `disconnect()`. Чтение `fs.received` с задержкой 50ms недетерминированно. На медленной машине или под CPU-нагрузкой `_handle` может не успеть прочитать все клиентские байты.

**Recommendation:** добавить `await asyncio.sleep(0)` после `disconnect()` (вместо фиксированного `0.05`) и сделать writer.close() внутри `_handle` до попытки чтения, либо использовать `asyncio.Event` для синхронизации.

### 7. `drain_one_client` — нет лога для `IO::WaitReadable`

**Plan**, строка 1096: `rescue IO::WaitReadable` — молчаливый возврат. Сегодня (single-client) это нормально — буфер drained, ждём следующий тик. Но в multi-client режиме с FIFO-очередью стоит логировать хотя бы на DEBUG, особенно для диагностики сценариев "клиент A читает 50 итераций подряд, клиент B даже не начал читаться". Это не баг, но усложняет отладку starvation.

### 8. `@clients.values.each` snapshot — безопасность итерации при удалении

**Plan**, строка 1077: `@clients.values.each do |state|`. `Hash#values` в Ruby возвращает новый Array — snapshot на момент вызова. Удаление из `@clients` через `close_client` не влияет на итерацию. Это корректно. Но стоит отметить: новый клиент, добавленный в `@clients` ПОСЛЕ снятия snapshot'а, не будет обслужен в этом тике. Поскольку `accept_pending_clients` вызывается ДО `drain_reads_all_clients`, а `drain_reads_all_clients` не добавляет новых клиентов, это безопасно.

### 9. `FakeSocket#write` не накапливает written при закрытом сокете

**Plan**, строка 682–685:
```ruby
def write(bytes)
  raise Errno::EPIPE, "Broken pipe" if @closed
  @written << bytes.b
  bytes.bytesize
end
```

Выбрасывает `EPIPE` вместо записи в `@written`. Это честно эмулирует поведение реального сокета. Но: если тест сначала проверяет `sock.closed?`, потом `sock.written`, всё хорошо. Если тест сначала проверяет `sock.written`, потом `sock.closed?` — `EPIPE` уронит тест до проверки. Во всех тестах плана порядок корректный, но это potential pitfall для будущих тестов.

### 10. `@frame_queue` — нет верхней границы

**Plan**, строка 1011: `@frame_queue = []`. Если клиент пайплайнит тысячи фреймов, очередь растёт неограниченно. Design §3 (non-goals) явно исключает per-tick cap. Но Design §5.4 говорит: "Pending frames belonging to the now-closed client are not removed from `@frame_queue`". Если клиент пайплайнит 10K фреймов и затем отключается, все 10K entry остаются в очереди и будут пропущены через `state.closed?` check. Каждый вызов `@frame_queue.shift` — O(1) амортизированный, так что 10K × O(1) = не страшно. Но это 10K итераций `process_frame_queue` в одном тике, потенциально замораживая SketchUp UI.

### 11. `test_send_once_does_not_require_server_version_in_response` — использует `get_version` как тестовый tool

**Plan**, строка 1920: `result = await conn.send_command("get_version", {})`. После изменений, `get_version` больше не bypass-инструмент — это обычный `tools/call`. Но в контексте мока `FakeServer` ответ поддельный: `{"content": [...], "isError": False}`. Реальный `get_version` вернул бы JSON с `python_version`, `ruby_version`, `compatible`. Но для теста "response без server_version не вызывает ошибку" это неважно — главное, что `_send_once` не проверяет `server_version`. Тест корректен по смыслу, но выбор `get_version` как имени tool'а сбивает с толку — лучше использовать произвольное имя вроде `"some_tool"`.

## Suggestions

### 12. FakeSocket helpers дублируются

Helpers `fr()` и `all_frames()` определены в **Plan** для `test_server_multi_client.rb` (строки 752–767) и повторно для `test_server_handshake.rb` (строки 1270–1284). Стоит вынести в `test/support/` вместе с `FakeSocket`. План этого не делает, что ведёт к копипасте.

### 13. `HELLO` константа использует `MIN_PYTHON` вместо exact-version check

**Plan**, строка 1614–1616:
```ruby
HELLO = fr("jsonrpc" => "2.0", "method" => "hello",
           "params" => { "client_version" => SU_MCP::Core::Compat::MIN_PYTHON },
           "id" => 0)
```

`MIN_PYTHON` может быть ниже чем `CLIENT_VERSION` в будущем (когда диапазон расширится). В тестах handshake используется `COMPAT_PYTHON = SU_MCP::Core::Compat::MIN_PYTHON` (строка 1287), что согласованно. Но семантически правильнее использовать точную версию, совместимую с сервером, а не нижнюю границу. Пока `MIN_PYTHON == MAX_PYTHON == "0.0.3"` это неважно.

### 14. `encode_response_body` fallback в Task 5 не выставляет `server_version`

**Plan**, строки 1573–1583: fallback-путь в `encode_response_body` ( rescue `JSON::GeneratorError`) генерирует `Errors.build_error_response(...)` БЕЗ `server_version`. Это сознательное решение — handshake уже покрыл версию. Но Design этого явно не обсуждает. Если `JSON::GeneratorError` произойдёт на post-handshake ответе, клиент получит error-envelope без `server_version` — это ожидаемо и корректно.

### 15. `handle_pre_handshake` — нет валидации `request["id"]`

**Plan**, строки 1497–1534: `handle_pre_handshake` проверяет envelope, method, params, версию — но не валидирует, что `request["id"]` присутствует. Если `hello` пришёл с `"id": null` или без `id`, `reject_handshake` вызывает `Errors.build_error_response(..., rid)` где `rid = nil`. Это порождает error-response с `"id": null`, что допустимо по JSON-RPC для ошибок разбора. Но семантически странно: мы отвечаем ошибкой на handshake-запрос, который технически является notification (нет id). Лучше молча закрыть — как для pre-handshake notifications.

В плане `handle_frame` проверяет `is_notification` до вызова `handle_pre_handshake`:
```ruby
if !state.handshaked
  if is_notification
    close_client(state, "pre_handshake_notification")
    return nil
  end
  handle_pre_handshake(state, request)
```
...но `is_notification = request.is_a?(Hash) && !request.key?("id")`. Если `"id": null` — `request.key?("id")` → `true`, так что `is_notification = false`. Запрос с `"id": null` попадёт в `handle_pre_handshake`, которое не ожидает такого случая. `reject_handshake` сделает `rid = request["id"]` → `null`, что приведёт к ответу с `"id": null`. По JSON-RPC 2.0 это допустимо для parse errors. Не критично, но некрасиво.

### 16. Plan-vs-Design по `encode_response_body`

**Design §5.3**, `write_response` (строка 402): вызывает `encode_response_body(response)`. **Plan Task 4** `encode_response_body` (строка 1155–1167) добавляет `server_version`. **Plan Task 5 Step 3d** (строка 1572–1583) убирает инъекцию. **Design §6.2** говорит что post-handshake ответы без `server_version`. Всё согласованно по конечному состоянию. Промежуточное состояние Task 4 — `server_version` всё ещё инъектируется — явно задокументировано в плане.

### 17. Предложение: `ClientState#closing_state` enum вместо `@close_after_response`

**Design §13.3** сам признаёт что `instance_variable_set(:@close_after_response, true)` — это shim. Предлагаю добавить `closing_state` enum (`nil`, `:after_response`) прямо сейчас, а не откладывать. Одно дополнительное поле в `ClientState` (`attr_accessor :closing_state`) и проверка в `write_response` (`if state.closing_state == :after_response`) не являются "API churn". Это чище, чем `instance_variable_get`/`set`, и легче расширяется. В плане сейчас 2 использования shim'а:
- `reject_handshake`: `state.instance_variable_set(:@close_after_response, true)`
- `write_response`: `state.instance_variable_get(:@close_after_response)`

## Questions

1. **Почему `send_transport_error` в `drain_one_client` передаёт `nil` как `request_id`?** Plan, строка 1102: `send_transport_error(state, e, nil)`. Framing-ошибка происходит до парсинга JSON, поэтому реальный `id` запроса неизвестен. JSON-RPC §5.1 допускает `"id": null` для parse-ошибок. Но framing-ошибка (zero-length/oversize) — это не совсем parse error. Корректно ли отвечать `"id": null` на framing-ошибку? Семантически — да, потому что мы не можем восстановить `id` из потока.

2. **Почему `drain_one_client` не логирует `IO::WaitReadable` даже на DEBUG?** Сегодня в single-client режиме это молчаливый возврат. Multi-client с FIFO — стоило бы добавить `Logger.log("DEBUG", ...)` для диагностики starvation.

3. **`test_server_compat.rb` в плане Task 3 называется `TestDispatchPostHandshake`, но файл называется `test_server_compat.rb`.** Имя класса и имя файла расходятся семантически: файл называется "compat", но тестирует Dispatch. Это историческое имя, но план не предлагает переименовать файл в `test_dispatch.rb` — возможно, стоит.

4. **Smoke test: почему `--n 3` создаёт 3 workers, но `workloads` список собирается как `[LIGHT, HEAVY] * args.n`?** Plan, строка 2289: `workloads = [LIGHT_WORKLOAD, HEAVY_WORKLOAD] * args.n`. При `--n 3` это создаст список из 6 элементов. Но затем цикл (строка 2291) использует `range(args.n)` — 3 итерации, первая LIGHT, остальные HEAVY. Список `workloads` больше нигде не используется. Это мёртвый код.
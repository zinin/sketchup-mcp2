# Deep-Review Batch 2 (P1-остатки + P2 + UX-квиквины) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть все оставшиеся P1/P2-находки deep-research-аудита (T-05, T-07, T-06, T-11…T-19, T-21…T-23, T-25…T-29), три кандидата финального mesh-ревью батча 1 (MR-1 partial-EOF retry, MR-2 min-dimensions, MR-3 rotated-board coverage) и три живых UX-квиквина (T-50, T-54, T-55) — одним батчем на ветке `fix/deep-review-p2`, финиш — единый PR в master с обоими батчами.

**Architecture:** Проект — мост Claude ↔ SketchUp: Python MCP-сервер (`src/sketchup_mcp/`, FastMCP + persistent TCP-клиент) и Ruby-расширение (`mcp_for_sketchup/mcp_for_sketchup/`, TCP-сервер внутри SketchUp). JSON-RPC 2.0 поверх 4-байтового length-prefix фрейминга. Все правки локальны; wire-протокол и handshake НЕ меняются. Дизайн-первоисточник: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`.

**Tech Stack:** Python ≥3.10 (pytest, pytest-asyncio `asyncio_mode=auto`, pydantic v2/FastMCP, mcp locked `>=1.27,<2`), Ruby 3.2 (minitest, stdlib + rubyzip только в package-тесте), GitHub Actions (уже настроен).

## Global Constraints

- **Единицы:** на границе MCP — миллиметры и градусы; внутри SketchUp — дюймы. Конвертация `MM = 25.4` (`helpers/units.rb`).
- **`Group#subtract` РЕВЕРСИРОВАН:** `A.subtract(B)` возвращает `B − A`. НИКОГДА не «исправлять» порядок аргументов; тесты `test/test_boolean_direction.rb`, `test/test_operation_names.rb` пинят это намеренно.
- **Literal source-guard тесты** пинят точный текст хендлеров (вплоть до отступов): `test/test_operation_names.rb`, `test/test_transform_absolute.rb`, `test/test_joints_frame_compensation.rb`. НИКАКИХ авто-форматтеров; при рефакторинге пины обновлять осознанно, отдельным шагом.
- **Ruby-тесты:** каждый `test/test_*.rb` обязан проходить (a) standalone `ruby test/test_<name>.rb` и (b) в одном процессе `ruby test/run_all.rb`. Глобальные стабы (`module Sketchup`, `module Geom`) — либо guarded (`unless defined?(...)`) для не-реопенимых конструкций (Struct, классы с константами), либо **аддитивный реопен классов** (эталон: шапка `test/test_collect_components.rb`) — реопен предпочтителен, когда файлу нужны конкретные аксессоры: guarded-скип чужого скупого стаба их бы не дал. Singleton-поверхности патчить в `setup`/`teardown` с сохранением `Method`-объекта (эталон: `test/test_collect_components.rb`, патч `Helpers::Entities.active_model!`); ⚠ это касается И модульных `def self.`-методов — они СУТЬ singleton-методы, «снять стаб» через `remove_method` без сохранённого `Method` под run_all удаляет реальный метод насовсем.
- **Прогоны и базлайны на старте батча:** Ruby — `ruby test/run_all.rb` → **354 runs / 939 assertions / 0 failures / 0 errors** (~1.4 с); Python — `uv run pytest tests/ -q` → **136 passed** (~2.4 с). На старте исполнения ПЕРЕПРОГНАТЬ оба базлайна и зафиксировать фактические числа в ledger (счётчики CLAUDE.md могли устареть).
- **Версии не бампаем** (ни `pyproject.toml`/`__init__.py`, ни Ruby `Compat::SERVER_VERSION`, ни `package.rb VERSION`, ни `extension.json`) — все четыре сейчас `0.2.0`. Wire-протокол/handshake не трогаем.
- **Contract break копится:** T-07/T-50/T-54 добавляют параметры, T-27/T-28/T-55 меняют формы ответов. Фиксация — в `docs/release.md`, блок «Pending contract break» (Task 16); MIN-floor'ы здесь НЕ трогаем.
- **Коммиты:** английские, conventional (`fix:`/`test:`/`feat:`/`docs:`), без AI-атрибуции. Рабочая директория — корень репо, ветка `fix/deep-review-p2`.
- **Отчёт-первоисточник** (`docs/deep-research-review-report.md`) закоммичен в ДРУГОЙ ветке (`docs/deep-research-review`); план самодостаточен, идентификаторы T-xx/MR-x — трассировка. ⚠ Номера строк в тикетах датируются 2026-06-12 — искать по содержимому.
- Python-окружение — через `uv` (`uv run pytest tests/ -q`). НЕ трогать `.venv.broken-task8/` и untracked-мусор корня до Task 16.

## Карта задач

| # | Тикеты | Суть | Волна |
|---|---|---|---|
| 1 | T-12, T-26 | config.py: валидация ENV + тест-гигиена reload | 1: Python-ядро |
| 2 | T-11 | connection.py: UnicodeDecodeError + голый OSError | 1 |
| 3 | MR-1 | retry read-only при partial-EOF | 1 |
| 4 | T-21, T-22 | версии: metadata-тест + Ruby-тройка; валидация через реальные схемы | 1 |
| 5 | T-06 | entity id как int \| str | 2: сигнатуры |
| 6 | T-50, T-54 | create_component: name + видимый дефолт dimensions | 2 |
| 7 | T-07 | пагинация list/find + быстрый get_component_info | 2 |
| 8 | T-55 | пустой bbox → null вместо сентинела 2.54e31 | 2 |
| 9 | T-28 | скриншот: метаданные width/height/preset/style | 2 |
| 10 | T-13 | server.rb: батч устойчивости ×5 | 3: Ruby-надёжность |
| 11 | T-14, T-15, T-19, T-27 | compat-сообщение, OBJ-ключ, Logger-guard, export-warning | 3 |
| 12 | T-16 | make_unique перед мутацией definition-entities | 3 |
| 13 | T-17, MR-2, T-18 | валидация параметров + min-dims + case-insensitive поиск | 3 |
| 14 | T-23, MR-3 | Ruby-тестовые пробелы + rotated-board coverage | 4: тесты/контракт |
| 15 | T-05 | докстринг-оверхол 22 тулов + prompts.py sync | 4 |
| 16 | T-25, T-29 | зачистка доков, .gitignore, entry-points, release.md | 5: финиш |
| 17 | — | финальная верификация, счётчики, smoke-синк | 5 |

Порядок строгий: 5–9 (сигнатуры) до 15 (T-05 документирует финальное API); 10 до 14 (T-23 тестирует новые пути server.rb); 13 до 15 (валидация меняет схемы); 16–17 последними. Задачи 7, 8, 13 трогают `handlers/model.rb` — выполнять последовательно, не параллелить.

---

### Task 1: config.py — валидация ENV-переменных (T-12) + тест-гигиена reload (T-26)

**Files:**
- Modify: `src/sketchup_mcp/config.py` (полная замена — файл 24 строки)
- Test: `tests/test_config.py`

**Interfaces:**
- Produces: `config.PORT/HOST/TIMEOUT/LOG_LEVEL/MAX_MESSAGE_SIZE` — имена и типы НЕ меняются; `setup_logging()` не меняется. Невалидный ENV теперь раняет `ValueError` с именем переменной при импорте модуля.
- Consumes: ничего из других задач.

- [ ] **Step 1: RED — тесты валидации в `tests/test_config.py`**

Добавить в конец файла (импорт `logging` добавить к существующим импортам в шапке):

```python
# --- T-12: валидация ENV при импорте ---

def test_invalid_port_raises_with_variable_name(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_PORT", "abc")
    with pytest.raises(ValueError, match="SKETCHUP_MCP_PORT"):
        reload_config()


@pytest.mark.parametrize("bad", ["0", "65536", "-5"])
def test_out_of_range_port_raises(env_clean, monkeypatch, bad):
    monkeypatch.setenv("SKETCHUP_MCP_PORT", bad)
    with pytest.raises(ValueError, match="1..65535"):
        reload_config()


@pytest.mark.parametrize("bad", ["abc", "0", "-1", "inf", "nan"])
def test_invalid_timeout_raises_with_variable_name(env_clean, monkeypatch, bad):
    monkeypatch.setenv("SKETCHUP_MCP_TIMEOUT", bad)
    with pytest.raises(ValueError, match="SKETCHUP_MCP_TIMEOUT"):
        reload_config()


def test_unknown_log_level_warns_and_falls_back_to_info(env_clean, monkeypatch, caplog):
    monkeypatch.setenv("SKETCHUP_MCP_LOG_LEVEL", "VERBOSE")
    with caplog.at_level(logging.WARNING):
        cfg = reload_config()
    assert cfg.LOG_LEVEL == "INFO"
    assert any("SKETCHUP_MCP_LOG_LEVEL" in r.getMessage() for r in caplog.records)


def test_warn_level_accepted(env_clean, monkeypatch):
    """Регрессия: задокументированный алиас WARN не должен попасть под warning."""
    monkeypatch.setenv("SKETCHUP_MCP_LOG_LEVEL", "warn")
    assert reload_config().LOG_LEVEL == "WARN"
```

⚠ В `caplog`-ассерте именно `r.getMessage()`: warning эмитится ленивым `%`-форматированием (`logger.warning("%s: ...", name, raw)`), но pytest'овский LogCaptureHandler уже форматирует record при emit — повторный `r.message % r.args` кинул бы `TypeError: not all arguments converted`.

- [ ] **Step 2: Прогнать — убедиться, что RED соответствует прогнозу**

Run: `uv run pytest tests/test_config.py -q`
Expected: **10 failed, 6 passed** (5 старых зелёных + новый `test_warn_level_accepted`). Провалы: port «abc» — ValueError без имени переменной (match не находит); port «0»/«65536»/«-5» и timeout «0»/«-1»/«inf»/«nan» — DID NOT RAISE; timeout «abc» — ValueError без имени; VERBOSE — LOG_LEVEL == "VERBOSE" ≠ "INFO". `test_warn_level_accepted` уже зелёный (пин текущего поведения).

- [ ] **Step 3: GREEN — новый `src/sketchup_mcp/config.py` (полная замена файла)**

```python
"""Environment-driven configuration for sketchup-mcp.

All values are read at module import. Tests reload the module via
``importlib.reload`` to pick up monkey-patched environment variables.
Invalid values raise ``ValueError`` naming the offending variable at
import time — fail-fast beats a silent fallback hiding a typo'd deploy
(T-12). Unknown LOG_LEVEL degrades to INFO with a warning instead of
silently masquerading as INFO.
"""
import logging
import math
import os

logger = logging.getLogger("sketchup_mcp.config")

_VALID_LOG_LEVELS = frozenset({"DEBUG", "INFO", "WARN", "WARNING", "ERROR", "CRITICAL"})


def _env_port(name: str, default: str) -> int:
    raw = os.getenv(name, default)
    try:
        port = int(raw)
    except ValueError:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from None
    if not 1 <= port <= 65535:
        raise ValueError(f"{name} must be in 1..65535, got {port}")
    return port


def _env_timeout(name: str, default: str) -> float:
    raw = os.getenv(name, default)
    try:
        timeout = float(raw)
    except ValueError:
        raise ValueError(f"{name} must be a number (seconds), got {raw!r}") from None
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError(f"{name} must be a finite number > 0 seconds, got {raw!r}")
    return timeout


def _env_log_level(name: str, default: str) -> str:
    raw = os.getenv(name, default).upper()
    if raw not in _VALID_LOG_LEVELS:
        logger.warning(
            "%s: unknown log level %r, falling back to INFO "
            "(valid: DEBUG, INFO, WARN, ERROR)",
            name,
            raw,
        )
        return "INFO"
    return raw


PORT: int = _env_port("SKETCHUP_MCP_PORT", "9876")
HOST: str = os.getenv("SKETCHUP_MCP_HOST", "127.0.0.1")
TIMEOUT: float = _env_timeout("SKETCHUP_MCP_TIMEOUT", "60")
LOG_LEVEL: str = _env_log_level("SKETCHUP_MCP_LOG_LEVEL", "INFO")

MAX_MESSAGE_SIZE: int = 64 * 1024 * 1024  # 64 MiB; запас для PNG/DAE/SKP-экспортов


def setup_logging() -> None:
    """Initialise root logger from ``LOG_LEVEL`` (force overrides existing handlers)."""
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        force=True,
    )
```

- [ ] **Step 4: Прогнать тесты config**

Run: `uv run pytest tests/test_config.py -q`
Expected: **16 passed** (5 старых + 11 новых).

- [ ] **Step 5: Полный прогон Python**

Run: `uv run pytest tests/ -q`
Expected: **147 passed** (136 + 11). Если что-то вне test_config.py упало — СТОП: валидация при импорте могла зацепить чужой reload; разобраться до коммита.

- [ ] **Step 6: Commit T-12**

```bash
git add src/sketchup_mcp/config.py tests/test_config.py
git commit -m "fix: validate SKETCHUP_MCP_* environment variables at import (T-12)"
```

- [ ] **Step 7: T-26 — module-scoped reload-фикстура в `tests/test_config.py`**

Добавить сразу после `env_clean` (фикстуры в шапке файла):

```python
@pytest.fixture(autouse=True, scope="module")
def restore_config_after_module():
    """T-26: не оставлять модуль config с окружением последнего теста.

    Тесты файла перегружают sketchup_mcp.config под monkeypatched ENV; без
    финального reload модуль оставался бы, например, с HOST="0.0.0.0" для
    всех последующих тестовых файлов сессии. Teardown module-scoped фикстуры
    выполняется ПОСЛЕ function-scoped восстановления ENV monkeypatch'ем,
    поэтому финальный reload читает уже реальное окружение.
    """
    yield
    importlib.reload(config_module)
```

- [ ] **Step 8: Проверить порядок финализации на практике**

Run: `uv run pytest tests/test_config.py tests/test_app.py -q && uv run python -c "import sketchup_mcp.config as c; print(c.HOST)"`
Expected: тесты passed; напечатан реальный `HOST` (по умолчанию `127.0.0.1`). Затем полный прогон: `uv run pytest tests/ -q` → **147 passed**.

- [ ] **Step 9: Commit T-26**

```bash
git add tests/test_config.py
git commit -m "test: reload config module after test_config completes (T-26)"
```

---

### Task 2: connection.py — дыры таксономии исключений (T-11)

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (метод `_handshake` — ветка `json.loads`; метод `_send_once` — ветка `json.loads` и блок except'ов роундтрипа)
- Test: `tests/test_connection.py`

**Interfaces:**
- Produces: не-UTF8 фрейм → `SketchUpError(-32700)`; голый `OSError` из роундтрипа → `disconnect()` + `SketchUpError(-32000)`. Классы/сигнатуры не меняются.
- Consumes: фикстуры `make_connection`/`fake_streams` из `tests/conftest.py`; хелперы `encode_frame`, `FakeServer` уже определены в `tests/test_connection.py` (низ файла).

- [ ] **Step 1: RED — три теста**

В `tests/test_connection.py`, рядом с `test_send_command_parse_error_disconnects` (~строка 106) добавить:

```python
async def test_send_command_non_utf8_frame_raises_parse_error(make_connection, fake_streams):
    """T-11: не-UTF8 тело фрейма → -32700 + disconnect, а не голый
    UnicodeDecodeError мимо `except json.JSONDecodeError` (PY-CONN-02)."""
    reader, _ = fake_streams
    conn = make_connection()
    bad = b'{"jsonrpc": "2.0", "id": 1, "result": "\xff\xfe"}'
    reader.feed_data(struct.pack(">I", len(bad)) + bad)
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {})
    assert exc_info.value.code == -32700
    assert conn._writer is None


async def test_send_command_raw_oserror_disconnects_and_wraps(make_connection, fake_streams):
    """T-11: голый OSError (EHOSTUNREACH/ENETUNREACH — задокументированный
    split-host сценарий; ETIMEDOUT на py3.10) должен войти в таксономию:
    disconnect + SketchUpError(-32000), НЕ _StaleSocketError (нет гарантии,
    что peer не обработал запрос) и НЕ голое исключение без disconnect
    (PY-CONN-03). Выбран именно EHOSTUNREACH: OSError(errno, ...) для
    ECONNRESET/EPIPE авто-инстанцирует подклассы ConnectionError — тест с
    «привычным» errno молча перестал бы проверять голую OSError-ветку."""
    import errno
    _, writer = fake_streams
    conn = make_connection()
    writer.drain = AsyncMock(side_effect=OSError(errno.EHOSTUNREACH, "No route to host"))
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("get_model_info", {})
    assert exc_info.value.code == -32000
    assert "No route to host" in exc_info.value.message
    assert conn._writer is None
```

В конец файла (после `FakeServer`-тестов, там где определён `encode_frame`):

```python
async def test_handshake_non_utf8_reply_raises_sketchup_error():
    """T-11: не-UTF8 тело hello-ответа → SketchUpError(-32700). До фикса голый
    UnicodeDecodeError пролетал сквозь lifespan-catch (ConnectionError,
    SketchUpError) и валил старт сервера вместо degraded-режима."""
    bad_body = b'{"jsonrpc": "2.0", "id": 0, "result": "\xff\xfe"}'
    async with FakeServer([encode_frame(bad_body)]) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
        assert ei.value.code == -32700
        assert "handshake parse error" in ei.value.message
```

- [ ] **Step 2: Прогнать — RED**

Run: `uv run pytest tests/test_connection.py -q`
Expected: **3 failed** (оба non-utf8 теста падают с `UnicodeDecodeError` вместо `SketchUpError`; OSError-тест — с голым `OSError`), остальные passed.

- [ ] **Step 3: GREEN — правки `src/sketchup_mcp/connection.py`**

3a. В `_handshake` заменить:

```python
        try:
            response = json.loads(response_body)
        except json.JSONDecodeError as e:
            raise SketchUpError(-32700, f"handshake parse error: {e}") from e
```

на:

```python
        try:
            response = json.loads(response_body)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            # UnicodeDecodeError: json.loads(bytes) декодирует UTF-8 сам;
            # не-UTF8 тело кидало голый UnicodeDecodeError мимо таксономии
            # (валил lifespan вместо degraded-старта). T-11/PY-CONN-02.
            raise SketchUpError(-32700, f"handshake parse error: {e}") from e
```

3b. В `_send_once` заменить:

```python
        try:
            response = json.loads(response_body)
        except json.JSONDecodeError as e:
            await self.disconnect()
            raise SketchUpError(-32700, f"parse error: {e}") from e
```

на:

```python
        try:
            response = json.loads(response_body)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            # См. _handshake: не-UTF8 тело = тот же parse-класс ошибок. T-11.
            await self.disconnect()
            raise SketchUpError(-32700, f"parse error: {e}") from e
```

3c. В `_send_once`, ПОСЛЕ блока `except ConnectionError as e:` (который поднимает `_StaleSocketError`) и ПЕРЕД `except SketchUpError:` вставить:

```python
        except OSError as e:
            # Голый OSError вне ConnectionError-подсемейства: EHOSTUNREACH /
            # ENETUNREACH (split-host из README), ETIMEDOUT на py3.10. Порядок
            # важен: ConnectionError ⊂ OSError, поэтому эта ветка стоит ПОСЛЕ.
            # НЕ _StaleSocketError: это не «peer закрыл сокет», гарантий о
            # необработанности запроса нет — retry не предлагаем. T-11.
            await self.disconnect()
            raise SketchUpError(-32000, f"connection error: {e}") from e
```

- [ ] **Step 4: Прогнать тесты**

Run: `uv run pytest tests/test_connection.py -q`
Expected: все passed (в файле стало на 3 теста больше).

- [ ] **Step 5: Полный прогон + commit**

Run: `uv run pytest tests/ -q`
Expected: **150 passed** (147 + 3).

```bash
git add src/sketchup_mcp/connection.py tests/test_connection.py
git commit -m "fix: catch UnicodeDecodeError and raw OSError in connection taxonomy (T-11)"
```

---

### Task 3: retry read-only тулов при partial-EOF (MR-1)

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (докстринг `_StaleSocketError`; ветка `except asyncio.IncompleteReadError` в `_send_once`)
- Test: `tests/test_connection.py` (новый тест + актуализация двух существующих)

**Interfaces:**
- Produces: `IncompleteReadError` с ЛЮБЫМ `partial` теперь маркируется `_StaleSocketError`; решение о retry остаётся за whitelist'ом `_RETRY_SAFE_TOOLS` в `send_command` (код не меняется). Для мутативных тулов partial-EOF теперь даёт ОБОГАЩЁННОЕ сообщение («NOT auto-retried…») вместо голого `connection error`.
- Consumes: `_RETRY_SAFE_TOOLS`, `_StaleSocketError` — существующие. P-14 (решение ревью): `get_viewport_screenshot` ОСТАЁТСЯ в whitelist — по данным ретрай идемпотентен (restore камеры в ensure отрабатывает до записи ответа), а скриншот — крупнейший ответ протокола и главный кандидат на обрыв посреди фрейма; редкое UX-мерцание документируется в докстринге тула (Task 15).

**Контекст решения (одобрено в дизайне):** батч 1 намеренно НЕ ретраил partial-EOF (партиал = peer начал отвечать = хендлер, возможно, выполнен). Для read-only тулов это перестраховка: у них нет побочных эффектов, повторный вызов безопасен независимо от того, выполнился ли хендлер. Safety-инвариант переносится целиком на whitelist.

- [ ] **Step 1: RED — новый тест (рядом с `test_send_command_retries_on_zero_byte_eof_for_readonly`)**

```python
async def test_send_command_retries_on_partial_read_for_readonly(make_connection, fake_streams):
    """MR-1 (mesh-ревью батча 1): обрыв ПОСРЕДИ ответа (partial != b"") для
    read-only тула теперь тоже ретраится. Побочных эффектов у whitelist-тулов
    нет — повтор безопасен, даже если Ruby успел выполнить хендлер. До фикса
    партиал давал голую SketchUpError без retry."""
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(b"\x00\x00")  # 2 байта из 4-байтового length-префикса
    reader.feed_eof()

    new_reader = asyncio.StreamReader()
    new_writer = MagicMock()
    new_writer.buffer = bytearray()
    new_writer.write = MagicMock(side_effect=lambda d: new_writer.buffer.extend(d))
    new_writer.drain = AsyncMock()
    new_writer.close = MagicMock()
    new_writer.wait_closed = AsyncMock()
    new_writer.is_closing = MagicMock(return_value=False)

    async def fake_connect():
        conn._reader = new_reader
        conn._writer = new_writer

    conn.connect = fake_connect
    # _next_id инкрементнут первой попыткой до 2 — retry уйдёт с rid=2.
    new_reader.feed_data(
        encode_response({"jsonrpc": "2.0", "id": 2, "result": {"ok": True}})
    )

    result = await conn.send_command("get_model_info", {})
    assert result == {"ok": True}
    sent_on_retry = decode_writer_frames(bytes(new_writer.buffer))
    assert len(sent_on_retry) == 1
    assert sent_on_retry[0]["params"]["name"] == "get_model_info"
```

- [ ] **Step 2: Прогнать — RED**

Run: `uv run pytest tests/test_connection.py::test_send_command_retries_on_partial_read_for_readonly -q`
Expected: FAIL — `SketchUpError: [-32000] connection error: ...` вместо результата (retry не случился).

- [ ] **Step 3: GREEN — правка `_send_once` + докстринг**

3a. Заменить ветку:

```python
        except asyncio.IncompleteReadError as e:
            await self.disconnect()
            if e.partial == b"":
                # 0 байт прочитано = peer закрыл соединение ДО отправки заголовка.
                # Гарантия: запрос не был обработан (иначе peer прислал бы
                # минимум 4 байта length-prefix). Safe-to-retry.
                raise _StaleSocketError(-32000, f"connection error: {e}") from e
            # Partial read = peer уже начал отвечать → мутация могла произойти,
            # retry небезопасен.
            raise SketchUpError(-32000, f"connection error: {e}") from e
```

на:

```python
        except asyncio.IncompleteReadError as e:
            # EOF до полного ответа — заголовок не пришёл вовсе (partial == b"")
            # или оборван посреди фрейма. Различие partial-пустоты больше НЕ
            # влияет на решение: безопасность retry целиком решает whitelist
            # в send_command (read-only тулы безопасно переспросить, даже если
            # Ruby успел выполнить хендлер; мутативные не ретраятся никогда).
            # MR-1 из финального ревью батча 1.
            await self.disconnect()
            raise _StaleSocketError(-32000, f"connection error: {e}") from e
```

3b. Заменить докстринг класса `_StaleSocketError` целиком:

```python
class _StaleSocketError(SketchUpError):
    """Маркер «транспорт умер посреди roundtrip'а» (EOF/RST до полного ответа).

    Сам по себе индикатор НЕДОСТАТОЧЕН для безопасного retry: Ruby-сторонний
    `write_response` может закрыть сокет **уже после** `model.commit_operation`
    (IO.select-таймаут 1 сек → reset_client). Даже partial == b"" не
    гарантирует, что мутация не применена (см. Codex review на PR #1).

    Поэтому retry ограничен whitelist'ом side-effect-free tools
    (`_RETRY_SAFE_TOOLS`) — их безопасно переспрашивать независимо от того,
    успел ли peer обработать запрос. Для мутативных — поднимаем наверх как
    транспортную ошибку с recovery-подсказкой (см. send_command).

    Цена MR-1: обрыв посреди большого ответа (например ~43 MiB скриншота)
    означает второй полный захват и передачу — безопасно, но дорого;
    осознанная цена за автовосстановление read-only вызовов.
    """
```

- [ ] **Step 4: Актуализировать два существующих теста**

4a. `test_send_command_no_retry_on_partial_read` — поведение для мутативного тула не изменилось (retry нет), но причина теперь «не в whitelist», и ошибка обогащена. Заменить докстринг и добавить ассерты обогащения (последними строками теста, после `conn.connect.assert_not_called()`):

Новый докстринг:

```python
    """Partial read для МУТАТИВНОГО тула: retry по-прежнему запрещён — тул не
    в _RETRY_SAFE_TOOLS (после MR-1 партиал-EOF маркируется _StaleSocketError,
    и решение принимает whitelist, а не сама партиал-эвристика). Ошибка теперь
    обогащается recovery-подсказкой, как и zero-byte случай."""
```

Дополнительные ассерты:

```python
    err = exc_info.value
    assert err.data.get("tool") == "mutate"
    assert "do NOT retry" in err.message  # фактический текст recovery-подсказки connection.py
```

4b. `test_send_command_retries_on_zero_byte_eof_for_readonly` — в докстринге упоминание «партиал не ретраится» осталось верным только для мутативных; поправить последнюю фразу докстринга с «Для READ-ONLY tools повтор безопасен …» — добавить в конец: `После MR-1 то же верно и для partial != b"" — см. test_send_command_retries_on_partial_read_for_readonly.`

- [ ] **Step 5: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **151 passed** (150 + 1).

```bash
git add src/sketchup_mcp/connection.py tests/test_connection.py
git commit -m "fix: retry read-only tools on mid-frame EOF (MR-1, batch-1 review follow-up)"
```

### Task 4: Версионные guard'ы и валидация через реальные схемы (T-21 + T-22)

**Files:**
- Modify: `tests/test_compat.py` (замена тавтологичного теста, строки 109–112)
- Create: `test/test_version_triple.rb`
- Modify: `tests/test_tools.py` (удалить TypeAdapter-зеркала строк 135–177, добавить dispatcher-тесты)

**Interfaces:**
- Consumes: `mcp` из `sketchup_mcp.app`; `MCPforSketchUp::Core::Compat::SERVER_VERSION`; паттерн `mcp.call_tool` из `tests/test_screenshot.py`.
- Produces: фикстура `dispatch_conn` в `tests/test_tools.py` — Tasks 5–7 переиспользуют её для своих схемо-тестов.

- [ ] **Step 1: T-21 Python — заменить тавтологичный тест**

В `tests/test_compat.py` заменить целиком:

```python
def test_python_version_is_imported_from_init():
    """compat.CLIENT_VERSION must mirror the package version."""
    from sketchup_mcp import __version__
    assert compat.CLIENT_VERSION == __version__
```

на:

```python
def test_python_version_matches_installed_metadata():
    """QUAL-03: старый тест сравнивал compat.CLIENT_VERSION с тем же атрибутом,
    из которого он импортирован, — тавтология. Настоящий guard: __version__
    (источник CLIENT_VERSION) обязан совпадать с версией из метаданных
    установленного пакета (pyproject.toml), иначе релизный бамп одной из двух
    точек тихо разъезжается."""
    from importlib.metadata import version
    assert compat.CLIENT_VERSION == version("sketchup-mcp2")
```

- [ ] **Step 2: Flip-проверка дискриминативности (обязательна — тест зелёный сразу)**

```bash
uv run pytest tests/test_compat.py -q                                  # PASS (обе точки 0.2.0)
sed -i 's/__version__ = "0.2.0"/__version__ = "9.9.9"/' src/sketchup_mcp/__init__.py
uv run pytest tests/test_compat.py::test_python_version_matches_installed_metadata -q   # обязан FAIL
git checkout src/sketchup_mcp/__init__.py
uv run pytest tests/test_compat.py -q                                  # снова PASS
```

Если flip НЕ дал провала — СТОП: metadata читается не из editable-install; разобраться (не коммитить слепо).

- [ ] **Step 3: T-21 Ruby — новый файл `test/test_version_triple.rb`**

```ruby
# test/test_version_triple.rb
# T-21: у релиза три Ruby-точки бампа версии — package.rb VERSION,
# extension.json "version" и Core::Compat::SERVER_VERSION. Loader пишет
# ext.version из package.rb, Extension Warehouse читает extension.json,
# handshake рапортует SERVER_VERSION — разъезд любой пары даёт .rbz с
# противоречивой самоидентификацией. Python-сторона закрыта зеркальным
# tests/test_compat.py::test_python_version_matches_installed_metadata.
require "minitest/autorun"
require "json"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"

class TestVersionTriple < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def server_version
    MCPforSketchUp::Core::Compat::SERVER_VERSION
  end

  def test_package_rb_version_matches_server_version
    src = File.read(File.join(ROOT, "mcp_for_sketchup", "package.rb"))
    m = src.match(/^VERSION = '([^']+)'/)
    refute_nil m, "package.rb: строка VERSION = '...' не найдена"
    assert_equal server_version, m[1],
      "package.rb VERSION (#{m[1]}) != Compat::SERVER_VERSION (#{server_version})"
  end

  def test_extension_json_version_matches_server_version
    meta = JSON.parse(File.read(File.join(ROOT, "mcp_for_sketchup", "extension.json")))
    assert_equal server_version, meta["version"],
      "extension.json version (#{meta['version']}) != Compat::SERVER_VERSION (#{server_version})"
  end
end
```

- [ ] **Step 4: Прогнать standalone + flip-проверка + run_all**

```bash
ruby test/test_version_triple.rb          # 2 runs, 0 failures
sed -i 's/"version": "0.2.0"/"version": "9.9.9"/' mcp_for_sketchup/extension.json
ruby test/test_version_triple.rb          # обязан FAIL (extension.json test)
git checkout mcp_for_sketchup/extension.json
ruby test/run_all.rb                      # 356 runs (354+2), 0 failures
```

- [ ] **Step 5: T-22 — заменить TypeAdapter-зеркала dispatcher-тестами**

В `tests/test_tools.py` УДАЛИТЬ четыре теста вместе с их локальным импорт-блоком (строки 135–177): `test_field_rejects_zero_or_negative_size`, `test_literal_rejects_value_outside_set`, `test_field_rejects_wrong_coord_length`, `test_dimensions_rejects_zero_or_negative_element` и строки `from typing import Annotated, Literal` / `from pydantic import Field, TypeAdapter, ValidationError` над ними.

На их место вставить:

```python
# --- T-22: валидация через РЕАЛЬНЫЕ схемы (mcp.call_tool), не TypeAdapter-зеркала.
# Убери Field(gt=0) из tools.py — зеркальный тест продолжил бы зеленеть, а эти
# упадут. Паттерн mcp.call_tool — как в tests/test_screenshot.py.
from sketchup_mcp.app import mcp


@pytest.fixture
def dispatch_conn():
    """Мокнутое соединение для вызовов через mcp.call_tool: валидация должна
    отработать ДО send_command; happy-path возвращает MCP-текст «ok»."""
    conn = MagicMock()
    conn.send_command = AsyncMock(return_value={"content": [{"text": "ok"}]})
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        yield conn


async def test_schema_rejects_zero_dimension(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, 0.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_negative_dimension(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, -2.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_wrong_dimensions_length(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_unknown_component_type(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"type": "pyramid"})
    assert "type" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_wrong_position_length_in_transform(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("transform_component", {"id": "5", "position": [1.0, 2.0]})
    assert "position" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_accepts_valid_create_component(dispatch_conn):
    """Happy-path сквозь реальный дispatcher: валидация пропускает, wire-вызов
    уходит с дефолтами. dimensions заданы явно, чтобы тест не зависел от
    смены дефолта в Task 6 (T-50)."""
    await mcp.call_tool("create_component", {"dimensions": [120.0, 60.0, 40.0]})
    dispatch_conn.send_command.assert_called_once_with(
        "create_component",
        {"type": "cube", "position": [0, 0, 0], "dimensions": [120.0, 60.0, 40.0]},
    )


async def test_schema_accepts_full_transform_combination(dispatch_conn):
    """T-22 (требование дизайна): happy-path полной комбинации
    position+rotation+scale — валидация пропускает, все три уходят на провод
    как есть (пин против случайной потери одного из optional-полей)."""
    await mcp.call_tool("transform_component", {
        "id": "5", "position": [1.0, 2.0, 3.0],
        "rotation": [0.0, 0.0, 90.0], "scale": [2.0, 1.0, 1.0]})
    dispatch_conn.send_command.assert_called_once_with(
        "transform_component",
        {"id": "5", "position": [1.0, 2.0, 3.0],
         "rotation": [0.0, 0.0, 90.0], "scale": [2.0, 1.0, 1.0]})
```

⚠ FastMCP оборачивает ValidationError в свой класс — ловим `Exception` и проверяем имя параметра в тексте (паттерн `test_screenshot.py`).

- [ ] **Step 6: Прогнать и посчитать**

Run: `uv run pytest tests/ -q`
Expected: **154 passed** (151 − 4 удалённых + 7 новых; версионный swap ±0). 0 failed.

- [ ] **Step 7: Commit**

```bash
git add tests/test_compat.py tests/test_tools.py test/test_version_triple.rb
git commit -m "test: real version guards and schema-level validation tests (T-21, T-22)"
```

---

### Task 5: Entity id как `int | str` (T-06)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (11 тулов с id-параметрами)
- Modify: `src/sketchup_mcp/prompts.py` (строка про Entity IDs в §3)
- Test: `tests/test_tools.py`

**Interfaces:**
- Produces: тип-алиас `EntityId = int | Annotated[str, Field(min_length=1)]` (module-level в tools.py); ВСЕ id-параметры принимают int и str; на провод всегда уходит `str(id)` — wire-формат не меняется (Ruby `require_id` парсит строку).
- Consumes: фикстура `dispatch_conn` из Task 4.

- [ ] **Step 1: RED — dispatcher-тесты (в `tests/test_tools.py`, после T-22-блока)**

```python
# --- T-06: id принимается и как int, и как str; на провод уходит str(id) ---

async def test_entity_id_accepts_int_and_forwards_as_str(dispatch_conn):
    """Хендлеры возвращают id как JSON-число; модель, отдающая его обратно
    без кавычек, не должна ловить ValidationError (T-06/PY-TOOLS-05)."""
    await mcp.call_tool("delete_component", {"id": 12345})
    dispatch_conn.send_command.assert_called_once_with(
        "delete_component", {"id": "12345"})


async def test_entity_id_str_passes_unchanged(dispatch_conn):
    await mcp.call_tool("get_component_info", {"id": "67"})
    dispatch_conn.send_command.assert_called_once_with(
        "get_component_info", {"id": "67"})


async def test_boolean_operation_accepts_int_ids(dispatch_conn):
    await mcp.call_tool("boolean_operation", {"target_id": 1, "tool_id": 2})
    dispatch_conn.send_command.assert_called_once_with(
        "boolean_operation",
        {"target_id": "1", "tool_id": "2",
         "operation": "union", "delete_originals": False})


async def test_empty_string_id_still_rejected(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("delete_component", {"id": ""})
    assert "id" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_entity_id_schema_exposes_int_and_string():
    """T-06: LLM-видимая схема id обязана предлагать ОБА типа —
    anyOf [{integer}, {string, minLength 1}]. Регистрация union в FastMCP
    проверена пробой на mcp 1.27; пин защищает от тихой деградации схемы
    (например, в {}) при апгрейде mcp."""
    tools = {t.name: t for t in await mcp.list_tools()}
    id_schema = tools["delete_component"].inputSchema["properties"]["id"]
    variants = {v.get("type") for v in id_schema.get("anyOf", [])}
    assert variants == {"integer", "string"}, f"unexpected id schema: {id_schema}"


async def test_bool_id_rejected(dispatch_conn):
    """P-05: bool — подкласс int; без strict-ветки True тихо коэрсился бы в
    id "1". Зелёный и ДО правки (id пока строго str) — роль теста: пин
    против bool-дыры ПОСЛЕ введения int-ветки."""
    with pytest.raises(Exception):
        await mcp.call_tool("delete_component", {"id": True})
    dispatch_conn.send_command.assert_not_called()
```

- [ ] **Step 2: Прогнать — RED**

Run: `uv run pytest tests/test_tools.py -q`
Expected: 4 новых FAIL (3 теста int-id ловят ValidationError на строгом `str`; schema-тест не находит anyOf — сейчас id-схема `{type: string, minLength: 1}`); 2 новых PASS — `test_empty_string_id_still_rejected` и `test_bool_id_rejected` (пины поведения: второй охраняет от bool-дыры после введения int-ветки).

- [ ] **Step 3: GREEN — правки tools.py**

3a. После строки `logger = logging.getLogger("sketchup_mcp.tools")` добавить:

```python
# T-06: хендлеры возвращают id как JSON-число (entity.entityID), а схемы
# требовали строго str — модель, отдающая {"id": 12345} обратно как int,
# получала ValidationError (клиентская коэрция это часто маскирует, но
# прямой call_tool — нет). Принимаем оба типа; на провод уходит str(id),
# wire-формат неизменен (Ruby require_id парсит строку).
# P-05: int-ветка СТРОГАЯ — bool является подклассом int, и без strict
# True тихо коэрсился бы в id "1" (валидная операция над чужой сущностью
# из мусорного вызова). Строка "3" при этом спокойно проходит str-веткой.
EntityId = Annotated[int, Field(strict=True)] | Annotated[str, Field(min_length=1)]
```

3b. Заменить типы и пробросы во всех 11 тулах (единый рецепт — тип `Annotated[str, Field(min_length=1)]` у id-полей меняется на `EntityId`, в пробросе `id=...` оборачивается `str(...)`):

| Тул | Параметры | Проброс |
|---|---|---|
| `delete_component` | `id: EntityId` | `id=str(id)` |
| `transform_component` | `id: EntityId` | `args: dict = {"id": str(id)}` |
| `set_material` | `id: EntityId` | `id=str(id), material=material` |
| `get_component_info` | `id: EntityId` | `id=str(id)` |
| `boolean_operation` | `target_id: EntityId, tool_id: EntityId` | `target_id=str(target_id), tool_id=str(tool_id)` |
| `chamfer_edge` | `id: EntityId` | `entity_id=str(id), distance=distance` |
| `fillet_edge` | `id: EntityId` | `entity_id=str(id), radius=radius, segments=segments` |
| `create_mortise_tenon` | `mortise_id: EntityId, tenon_id: EntityId` | `mortise_id=str(mortise_id), tenon_id=str(tenon_id)` |
| `create_dovetail` | `tail_id: EntityId, pin_id: EntityId` | `tail_id=str(tail_id), pin_id=str(pin_id)` |
| `create_finger_joint` | `board1_id: EntityId, board2_id: EntityId` | `board1_id=str(board1_id), board2_id=str(board2_id)` |

Пример (delete_component, целиком):

```python
@mcp.tool()
async def delete_component(
    ctx: Context,
    id: EntityId,
) -> str:
    """Delete a component by entity ID."""
    return await _call(ctx, "delete_component", id=str(id))
```

3c. В `prompts.py` заменить строку:

```
- Entity IDs are integers but accept strings (server casts via .to_i).
```

на:

```
- Entity IDs: pass them back exactly as returned — integer or string,
  both are accepted by every id parameter.
```

- [ ] **Step 4: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **160 passed** (154 + 6). Существующая параметризация `test_tool_wrapper_calls_ruby_correctly` передаёт id строками — проходит без правок (str→str неизменен).

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/prompts.py tests/test_tools.py
git commit -m "feat: accept entity ids as int or str across all id parameters (T-06)"
```

---

### Task 6: create_component — `name` + видимый дефолт dimensions (T-54 + T-50)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (`create_component`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (`create_component`)
- Test: `tests/test_tools.py`, `test/test_geometry_builders.rb`

**Interfaces:**
- Produces: Python `create_component(..., name: Optional[str] = None)`, дефолт `dimensions=[100, 100, 100]`; `name` уходит на провод ТОЛЬКО когда задан. Ruby: `params["name"]` опционален, валидируется `V.require_string` при наличии, применяется `group.name = name`.
- Consumes: `dispatch_conn` (Task 4); `EntityId`-стиль правок (Task 5) уже в файле.

- [ ] **Step 1: RED — Python-тесты (в `tests/test_tools.py`)**

```python
# --- T-50 + T-54: видимый дефолт dimensions; опциональный name ---

async def test_create_component_default_dimensions_visible(dispatch_conn):
    """T-50: дефолт [1,1,1] мм — невидимый кубик (тот же класс бага, что чинили
    в joints: «1.0 inch становится невидимым 1 mm»). Теперь [100,100,100]."""
    await mcp.call_tool("create_component", {})
    dispatch_conn.send_command.assert_called_once_with(
        "create_component",
        {"type": "cube", "position": [0, 0, 0], "dimensions": [100, 100, 100]},
    )


async def test_create_component_forwards_name_when_given(dispatch_conn):
    """T-54: name уходит на провод только когда задан (wire-совместимость)."""
    await mcp.call_tool("create_component", {"name": "TableLeg"})
    wire_args = dispatch_conn.send_command.call_args.args[1]
    assert wire_args["name"] == "TableLeg"


async def test_create_component_omits_name_when_absent(dispatch_conn):
    await mcp.call_tool("create_component", {})
    wire_args = dispatch_conn.send_command.call_args.args[1]
    assert "name" not in wire_args


async def test_create_component_rejects_empty_name(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"name": ""})
    assert "name" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()
```

Run: `uv run pytest tests/test_tools.py -q` → 4 новых FAIL (default [1,1,1]; name — unexpected keyword).

- [ ] **Step 2: GREEN — Python `create_component`**

Заменить сигнатуру и тело:

```python
@mcp.tool()
async def create_component(
    ctx: Context,
    type: Literal["cube", "cylinder", "cone", "sphere"] = "cube",
    position: Annotated[list[float], Field(min_length=3, max_length=3)] = [0, 0, 0],
    dimensions: Annotated[
        list[Annotated[float, Field(gt=0)]],
        Field(min_length=3, max_length=3),
    ] = [100, 100, 100],
    name: Optional[Annotated[str, Field(min_length=1)]] = None,
) -> str:
    """Create a new component in Sketchup."""
    args: dict = {"type": type, "position": position, "dimensions": dimensions}
    if name is not None:
        args["name"] = name
    return await _call(ctx, "create_component", **args)
```

(Докстринг остаётся кратким — полный оверхол в Task 15.)

- [ ] **Step 3: Прогнать Python**

Run: `uv run pytest tests/ -q`
Expected: **164 passed** (160 + 4). Wire-pin строка create_component в `test_tool_wrapper_calls_ruby_correctly` передаёт dimensions явно — не задета.

- [ ] **Step 4: RED — Ruby-тест name (в `test/test_geometry_builders.rb`)**

4a. В шапке файла ПЕРЕД блоком `module MCPforSketchUp ... module Validation; end ...` добавить require реальных units/validation (они чистые, зависят только от errors):

```ruby
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
```

(Пустые реопены `module Validation; end` ниже безвредны — методы уже определены.)

4b. Добавить guarded-стаб Sketchup (нужен `describe_entity`; под run_all модуль уже определён test_collect_components.rb):

```ruby
unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end
```

4c. В конец файла — новый тест-класс (handler-уровень через сферный билдер, Entities-методы стабятся с сохранением Method-объектов — паттерн test_collect_components.rb):

```ruby
class TestCreateComponentName < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry

  FakePoint = Struct.new(:x, :y, :z)
  FakeBounds = Struct.new(:min, :max)

  class NamedGroup
    attr_reader :entities
    attr_accessor :name
    def initialize
      @entities = TestGeometryBuilders::FaceCollector.new
      @name = ""
    end
    def entityID; 42; end
    def bounds
      FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(4, 4, 4))
    end
  end

  class NamedEntities
    attr_reader :group
    def add_group
      @group = NamedGroup.new
    end
  end

  class FakeModel
    attr_reader :active_entities
    def initialize
      @active_entities = NamedEntities.new
    end
    def start_operation(*); true; end
    def commit_operation; true; end
    def abort_operation; true; end
  end

  def with_fake_model(model)
    e = MCPforSketchUp::Helpers::Entities
    original = e.respond_to?(:active_model!) ? e.method(:active_model!) : nil
    e.define_singleton_method(:active_model!) { model }
    yield
  ensure
    if original
      e.define_singleton_method(:active_model!, original)
    else
      e.singleton_class.send(:remove_method, :active_model!)
    end
  end

  def create_sphere(extra = {})
    params = {
      "type" => "sphere",
      "dimensions" => [100.0, 100.0, 100.0],
    }.merge(extra)
    model = FakeModel.new
    result = with_fake_model(model) { GEO.create_component(params) }
    [model, result]
  end

  def test_name_applied_when_given
    model, result = create_sphere("name" => "Ball")
    assert_equal "Ball", model.active_entities.group.name
    assert_equal "Ball", result["name"]
  end

  def test_name_absent_leaves_default
    model, _result = create_sphere
    assert_equal "", model.active_entities.group.name
  end

  def test_empty_name_rejected
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      create_sphere("name" => "")
    end
    assert_equal(-32602, err.code)
  end
end
```

Run: `ruby test/test_geometry_builders.rb` → RED: `test_name_applied_when_given` падает (name не применяется), `test_empty_name_rejected` падает (не валидируется). ⚠ Если RED другой (например, NameError на describe_entity) — остановиться и разобраться со стабами, не подгонять.

- [ ] **Step 5: GREEN — Ruby `create_component` в `handlers/geometry.rb`**

В начале метода (после строки с `segments = ...`) добавить:

```ruby
        # T-54: опциональное имя группы. Без него все созданные группы
        # безымянны — find_components(name=...) бессилен, а модель не может
        # назвать то, что строит, иначе как через eval_ruby.
        name = params.key?("name") ? V.require_string(params, "name") : nil
```

После `case type ... end` (присвоение `group`) и ПЕРЕД `model.commit_operation`:

```ruby
          group.name = name if name
```

- [ ] **Step 6: Прогнать Ruby (standalone + run_all)**

```bash
ruby test/test_geometry_builders.rb   # 0 failures (в файле +3 runs)
ruby test/run_all.rb                  # 359 runs (356+3), 0 failures
```

- [ ] **Step 7: Commit**

```bash
git add src/sketchup_mcp/tools.py tests/test_tools.py mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb test/test_geometry_builders.rb
git commit -m "feat: optional name for create_component; visible default dimensions (T-54, T-50)"
```

---

### Task 7: Пагинация интроспекции + быстрый lookup (T-07)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb` (`list_components`, `find_components`, `get_component_info`, новые `paginate`/`find_component_by_id`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb` (новые `optional_int_nonneg`, `optional_enum`)
- Modify: `src/sketchup_mcp/tools.py` (`list_components`, `find_components` — новые параметры)
- Test: `test/test_model_pagination.rb` (новый), `tests/test_tools.py`

**Interfaces:**
- Produces: ответ `list_components`/`find_components` — `{"components": [...], "total": N, "offset": M, "truncated": bool}`; параметры `limit` (1..500, дефолт 50), `offset` (≥0, дефолт 0), `response_format` (`"concise"|"detailed"`, дефолт `"detailed"`; concise режет каждый элемент до `{id, name, type, layer, depth}` — layer включён по C-03: фильтрация по слою — частый сценарий, поле дешёвое). `V.optional_int_nonneg(params, key, default)`, `V.optional_enum(params, key, allowed, default)`, `V.optional_int_range(params, key, min:, max:, default:)`. `Model.find_component_by_id(entities, target_id, parent_t, depth:, max_depth:, seen:)` — DFS с ранним выходом, возвращает describe-хеш или nil.
- Consumes: `collect_components`/`describe_component` (существующие), `dispatch_conn` (Task 4).
- ⚠ Смена формы ответа — существующие консюмеры: `examples/smoke_check.py` (синк в Task 17), докстринги (Task 15).

- [ ] **Step 1: Ruby V-хелперы (в `helpers/validation.rb`, после `optional_int_positive`)**

```ruby
      def self.optional_int_nonneg(params, key, default = nil)
        return default unless params.key?(key)
        v = params[key]
        raise E.new(-32602, "field #{key} must be an integer") unless v.is_a?(Integer)
        raise E.new(-32602, "field #{key} must be >= 0, got #{v}") unless v >= 0
        v
      end

      def self.optional_enum(params, key, allowed, default = nil)
        return default unless params.key?(key)
        require_enum(params, key, allowed)
      end

      # P-04 (ревью): верхняя граница на Ruby-стороне — контракт «1..500»
      # обязан держаться и для direct-TCP клиентов, а не только через
      # Python-схему (Field(le=500)).
      def self.optional_int_range(params, key, min:, max:, default:)
        return default unless params.key?(key)
        v = params[key]
        raise E.new(-32602, "field #{key} must be an integer") unless v.is_a?(Integer)
        unless v.between?(min, max)
          raise E.new(-32602, "field #{key} must be in #{min}..#{max}, got #{v}")
        end
        v
      end
```

- [ ] **Step 2: RED — Ruby-тесты, новый файл `test/test_model_pagination.rb`**

Стабы — копия минимальных из `test_collect_components.rb` (реопен под run_all безвреден):

```ruby
# test/test_model_pagination.rb
# T-07: пагинация list_components/find_components + точечный
# get_component_info-lookup с ранним выходом (без полного обхода модели).
require "minitest/autorun"
require "set"

module Sketchup
  class Group
    attr_accessor :entities, :name, :entityID, :transformation, :bounds, :layer
    def initialize
      @transformation = Geom::Transformation.new
      @entities = []
    end
    def valid?; true; end
  end

  class ComponentDefinition
    attr_accessor :entities, :entityID
    def initialize
      @entities = []
    end
  end

  class ComponentInstance
    attr_accessor :definition, :name, :entityID, :transformation, :bounds, :layer
    def initialize
      @transformation = Geom::Transformation.new
    end
    def valid?; true; end
  end
end

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z)
      @x, @y, @z = x, y, z
    end
  end

  class BoundingBox
    attr_reader :min, :max
    def initialize(min, max)
      @min = min
      @max = max
    end
  end

  class Transformation
    def initialize; end
    def *(other); other; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"

class TestModelPagination < Minitest::Test
  M = MCPforSketchUp::Handlers::Model
  E = MCPforSketchUp::Helpers::Entities

  def make_layer(name)
    layer = Object.new
    layer.define_singleton_method(:name) { name }
    layer
  end

  def make_group(name:, id:)
    g = Sketchup::Group.new
    g.name = name
    g.entityID = id
    g.layer = @layer
    g.bounds = Geom::BoundingBox.new(
      Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 1))
    g
  end

  def setup
    @layer = make_layer("Layer0")
    @groups = (1..7).map { |i| make_group(name: "G#{i}", id: i) }
    model = Object.new
    entities = @groups
    model.define_singleton_method(:entities) { entities }
    @model = model
  end

  def with_model_stub
    original = E.method(:active_model!)
    model = @model
    E.define_singleton_method(:active_model!) { model }
    yield
  ensure
    E.define_singleton_method(:active_model!, original)
  end

  def test_list_components_paginates_with_metadata
    with_model_stub do
      page1 = M.list_components({ "limit" => 3, "offset" => 0 })
      assert_equal %w[G1 G2 G3], page1["components"].map { |c| c["name"] }
      assert_equal 7, page1["total"]
      assert_equal 0, page1["offset"]
      assert_equal true, page1["truncated"]

      page3 = M.list_components({ "limit" => 3, "offset" => 6 })
      assert_equal %w[G7], page3["components"].map { |c| c["name"] }
      assert_equal false, page3["truncated"]
    end
  end

  def test_list_components_offset_beyond_total_returns_empty_page
    with_model_stub do
      page = M.list_components({ "limit" => 3, "offset" => 100 })
      assert_equal [], page["components"]
      assert_equal 7, page["total"]
      assert_equal false, page["truncated"]
    end
  end

  def test_list_components_concise_strips_heavy_fields
    with_model_stub do
      page = M.list_components({ "limit" => 2, "response_format" => "concise" })
      entry = page["components"].first
      assert_equal %w[depth id layer name type], entry.keys.sort
      refute entry.key?("bbox_mm")
    end
  end

  def test_list_components_default_shape_still_detailed
    with_model_stub do
      page = M.list_components({})
      assert page["components"].first.key?("bbox_mm"),
        "дефолт (detailed) обязан сохранить bbox_mm — обратная совместимость"
      assert_equal 7, page["total"]
    end
  end

  def test_list_components_rejects_bad_pagination_params
    with_model_stub do
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.list_components({ "limit" => 0 }) }
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.list_components({ "limit" => 501 }) }
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.list_components({ "offset" => -1 }) }
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.list_components({ "response_format" => "tiny" }) }
    end
  end

  def test_find_components_paginates_too
    with_model_stub do
      res = M.find_components({ "name" => "G", "limit" => 2, "offset" => 0 })
      assert_equal 2, res["components"].length
      assert_equal 7, res["total"]
      assert_equal true, res["truncated"]
    end
  end

  def test_find_component_by_id_early_exit_does_not_touch_later_siblings
    # Бомба на id=7: обход, дошедший до последнего сиблинга ПОСЛЕ находки
    # id=1, взорвётся. Ранний выход обязан вернуться до неё.
    bomb = @groups.last
    bomb.define_singleton_method(:entityID) { raise "full traversal detected" }
    with_model_stub do
      found = M.find_component_by_id(
        @model.entities, 1, Geom::Transformation.new,
        depth: 0, max_depth: 64, seen: Set.new)
      assert_equal "G1", found["name"]
    end
  end

  def test_get_component_info_uses_targeted_lookup
    target = @groups[2] # G3
    e = MCPforSketchUp::Helpers::Entities
    orig_find = e.method(:find!)
    orig_rgc  = e.method(:require_group_or_component!)
    e.define_singleton_method(:find!) { |_id| target }
    e.define_singleton_method(:require_group_or_component!) { |entity, *| entity }
    with_model_stub do
      info = M.get_component_info({ "id" => 3 })
      assert_equal "G3", info["name"]
      assert_equal 0, info["depth"]
    end
  ensure
    e.define_singleton_method(:find!, orig_find)
    e.define_singleton_method(:require_group_or_component!, orig_rgc)
  end
end
```

Run: `ruby test/test_model_pagination.rb` → RED: пагинационные тесты падают (`total` отсутствует, `limit` игнорируется, `find_component_by_id` не определён).

- [ ] **Step 3: GREEN — правки `handlers/model.rb`**

3a. Константы рядом с `DEFAULT_MAX_DEPTH`:

```ruby
      DEFAULT_LIMIT = 50
      LIMIT_MAX     = 500   # верхняя граница limit — зеркало Python Field(le=500)
```

3b. `list_components` — заменить тело:

```ruby
      def self.list_components(params)
        recursive = params.fetch("recursive", false)
        max_depth = params.fetch("max_depth", DEFAULT_MAX_DEPTH)
        limit, offset, response_format = pagination_params(params)
        m = E.active_model!
        identity = Geom::Transformation.new
        seen = Set.new
        components = collect_components(m.entities, identity,
                                        recursive: recursive,
                                        depth: 0,
                                        max_depth: max_depth,
                                        seen: seen)
        paginate(components, limit, offset, response_format)
      end
```

3c. Общие хелперы (после `describe_component`):

```ruby
      # T-07: единые параметры и форма пагинации для list/find. Без лимитов
      # рекурсивный обход тяжёлой модели выгружал мегабайты JSON прямо в
      # контекст модели (отказ только на 64 MiB фрейм-капе).
      # P-03 (решение ревью): обход остаётся ПОЛНЫМ (collect + slice) —
      # точный total иначе не получить, а обход всей модели был нормой
      # этого хендлера и до пагинации; цель тикета — размер ОТВЕТА, и она
      # достигнута. Материализация хешей вне страницы — не bottleneck для
      # реальных SketchUp-моделей; traversal-аккумулятор отклонён как
      # сложность без болевой точки.
      def self.pagination_params(params)
        [
          V.optional_int_range(params, "limit", min: 1, max: LIMIT_MAX, default: DEFAULT_LIMIT),
          V.optional_int_nonneg(params, "offset", 0),
          V.optional_enum(params, "response_format", %w[concise detailed], "detailed"),
        ]
      end

      def self.paginate(components, limit, offset, response_format)
        page = components.slice(offset, limit) || []
        if response_format == "concise"
          page = page.map { |c| c.slice("id", "name", "type", "layer", "depth") }
        end
        {
          "components" => page,
          "total"      => components.length,
          "offset"     => offset,
          "truncated"  => offset + page.length < components.length,
        }
      end
```

3d. `find_components` — после строки `max_depth = params.fetch(...)` добавить `limit, offset, response_format = pagination_params(params)`; заменить финальную строку `{ "components" => results }` на `paginate(results, limit, offset, response_format)`.

3e. Точечный lookup — добавить после `collect_components`:

```ruby
      # T-07: тот же DFS, что collect_components (включая path-local cycle
      # guard), но с ранним выходом на первом совпадении id — get_component_info
      # больше не обходит всю модель ради одного entity.
      def self.find_component_by_id(entities, target_id, parent_t, depth:, max_depth:, seen:)
        return nil if depth > max_depth
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          return describe_component(entity, parent_t, depth: depth) if entity.entityID == target_id
          def_id = nil
          if entity.is_a?(Sketchup::ComponentInstance)
            def_id = entity.definition.entityID
            next if seen.include?(def_id)
            seen.add(def_id)
          end
          begin
            found = find_component_by_id(E.entity_collection(entity), target_id,
                                         parent_t * entity.transformation,
                                         depth: depth + 1, max_depth: max_depth,
                                         seen: seen)
            return found if found
          ensure
            seen.delete(def_id) if def_id
          end
        end
        nil
      end
```

3f. `get_component_info` — заменить две строки `all = collect_components(...)` / `all.find {...} || describe_component(entity)` на:

```ruby
        find_component_by_id(m.entities, entity.entityID, Geom::Transformation.new,
                             depth: 0, max_depth: LOOKUP_MAX_DEPTH, seen: Set.new) ||
          describe_component(entity)
```

Комментарий над методом обновить: убрать слова «Reuses collect_components» → «Uses find_component_by_id (early-exit DFS, same world-frame math as collect_components)»; остальной текст (fallback, LOOKUP_MAX_DEPTH) остаётся верным. NB (M-02): константа `LOOKUP_MAX_DEPTH` уже СУЩЕСТВУЕТ в model.rb — не переопределять. Дополнить комментарий метода фразой (C-07): fallback `describe_component(entity)` отдаёт bbox в parent-frame (identity-трансформация) — для сущностей глубже LOOKUP_MAX_DEPTH точность bbox деградирует; осознанно, глубина 64 в живых моделях не встречается.

- [ ] **Step 4: Прогнать Ruby**

```bash
ruby test/test_model_pagination.rb     # 8 runs, 0 failures
ruby test/test_collect_components.rb   # без регрессий (world-frame тест жив)
ruby test/run_all.rb                   # 367 runs (359+8), 0 failures
```

- [ ] **Step 5: RED — Python-параметры**

В `tests/test_tools.py` добавить:

```python
# --- T-07: пагинация интроспекции ---

async def test_list_components_forwards_pagination(dispatch_conn):
    await mcp.call_tool("list_components", {"limit": 10, "offset": 20,
                                            "response_format": "concise"})
    dispatch_conn.send_command.assert_called_once_with(
        "list_components",
        {"recursive": False, "max_depth": 3,
         "limit": 10, "offset": 20, "response_format": "concise"})


async def test_pagination_rejects_out_of_range(dispatch_conn):
    for bad_args in ({"limit": 0}, {"limit": 501}, {"offset": -1},
                     {"response_format": "tiny"}):
        with pytest.raises(Exception):
            await mcp.call_tool("list_components", bad_args)
    dispatch_conn.send_command.assert_not_called()


async def test_find_components_forwards_pagination(dispatch_conn):
    await mcp.call_tool("find_components", {"name": "leg", "limit": 5})
    dispatch_conn.send_command.assert_called_once_with(
        "find_components",
        {"name": "leg", "max_depth": 3,
         "limit": 5, "offset": 0, "response_format": "detailed"})
```

Обновить wire-pin таблицу `test_tool_wrapper_calls_ruby_correctly` — пять строк получают новые дефолты в expected kwargs:

- `("list_components", {}, ...)` → expected: `{"recursive": False, "max_depth": 3, "limit": 50, "offset": 0, "response_format": "detailed"}`
- `("list_components", {"recursive": True, "max_depth": 5}, ...)` → expected: `{"recursive": True, "max_depth": 5, "limit": 50, "offset": 0, "response_format": "detailed"}`
- `("find_components", {}, ...)` → expected: `{"max_depth": 3, "limit": 50, "offset": 0, "response_format": "detailed"}`
- `("find_components", {"name": "Casting"}, ...)` → expected: `{"name": "Casting", "max_depth": 3, "limit": 50, "offset": 0, "response_format": "detailed"}`
- `("find_components", {"name": "X", "layer": "Frame_BSR", "type": "group", "max_depth": 5}, ...)` → expected: `{"name": "X", "layer": "Frame_BSR", "type": "group", "max_depth": 5, "limit": 50, "offset": 0, "response_format": "detailed"}`

Run: `uv run pytest tests/test_tools.py -q` → RED (unexpected keyword `limit` + 5 wire-pin провалов).

- [ ] **Step 6: GREEN — Python-сигнатуры**

`list_components` — заменить целиком:

```python
@mcp.tool()
async def list_components(
    ctx: Context,
    recursive: bool = False,
    max_depth: Annotated[int, Field(ge=1, le=10)] = 3,
    limit: Annotated[int, Field(ge=1, le=500)] = 50,
    offset: Annotated[int, Field(ge=0)] = 0,
    response_format: Literal["concise", "detailed"] = "detailed",
) -> str:
    """List groups and component instances in the model (paginated).

    Returns {components: [...], total, offset, truncated}. Each component is
    {id, name, type, layer, depth, bbox_mm} (detailed) or {id, name, type,
    layer, depth} (concise). Bounds are in world coordinates. Set
    recursive=true to descend into nested components (bounded by max_depth,
    default 3).
    """
    return await _call(ctx, "list_components", recursive=recursive,
                       max_depth=max_depth, limit=limit, offset=offset,
                       response_format=response_format)
```

`find_components` — добавить те же три параметра после `max_depth` и включить их в `args`:

```python
    args: dict = {"max_depth": max_depth, "limit": limit, "offset": offset,
                  "response_format": response_format}
```

(остальные условные добавления name/layer/type — без изменений).

- [ ] **Step 7: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **167 passed** (164 + 3; правки таблицы счётчик не меняют).

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb src/sketchup_mcp/tools.py test/test_model_pagination.rb tests/test_tools.py
git commit -m "feat: paginate list/find introspection, early-exit component lookup (T-07)"
```

---

### Task 8: Пустой bbox → null вместо сентинела 2.54e31 (T-55)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb` (`get_model_info`, `describe_component`, новый `bbox_mm_or_nil`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (`describe_entity`)
- Test: `test/test_model_empty_bbox.rb` (новый)

**Interfaces:**
- Produces: везде, где наружу уходит `bounding_box_mm`/`bbox_mm`, пустые bounds (инвертированный сентинел SketchUp: `min > max`, ±1e30 дюймов) дают `null` вместо ±2.54e31. Предикат `Helpers::Geometry.empty_bbox?(bb)` (проверяет ВСЕ три оси — P-11 ревью) + хелпер `Model.bbox_mm_or_nil(bb)`; оба inline-сайта (`describe_component`, `describe_entity`) обязаны использовать предикат, не дублировать условие.
- Consumes: стабы Sketchup/Geom (паттерн Task 7).
- ⚠ Форма ответа: потребители из Task 15 (докстринги: «bbox_mm may be null»), Task 17 (smoke не задет — там непустые entity). C-06: Python-обёртки пробрасывают JSON-текст ответов прозрачно — валидации форм ответов на Python-стороне НЕТ, `null` безопасен по построению; это констатация, кода не требует.

- [ ] **Step 1: RED — новый файл `test/test_model_empty_bbox.rb`**

Шапка — та же пара стабов Sketchup/Geom + require, что в `test/test_model_pagination.rb` (Step 2 Task 7; скопировать дословно, реопен безвреден). Дополнительно require geometry-хендлера НЕ нужен — для describe_entity см. ниже. Тесты:

```ruby
class TestModelEmptyBbox < Minitest::Test
  M = MCPforSketchUp::Handlers::Model
  E = MCPforSketchUp::Helpers::Entities

  # Инвертированный empty-bbox SketchUp: min = +1e30", max = -1e30".
  SENTINEL = 1.0e30

  def empty_bbox
    Geom::BoundingBox.new(
      Geom::Point3d.new(SENTINEL, SENTINEL, SENTINEL),
      Geom::Point3d.new(-SENTINEL, -SENTINEL, -SENTINEL))
  end

  def make_layer(name)
    layer = Object.new
    layer.define_singleton_method(:name) { name }
    layer
  end

  def test_get_model_info_empty_model_returns_null_bbox
    model = Object.new
    bb = empty_bbox
    layers = Object.new
    layers.define_singleton_method(:map) { |&blk| [] }
    entities = []
    model.define_singleton_method(:path) { "" }
    model.define_singleton_method(:title) { "" }
    model.define_singleton_method(:bounds) { bb }
    model.define_singleton_method(:entities) { entities }
    model.define_singleton_method(:layers) { layers }

    e = MCPforSketchUp::Helpers::Entities
    original = e.method(:active_model!)
    e.define_singleton_method(:active_model!) { model }
    begin
      info = M.get_model_info({})
      assert_nil info["bounding_box_mm"],
        "пустая модель обязана отдавать null, а не сентинел ±2.54e31"
      assert_equal 0, info["entity_count"]
    ensure
      e.define_singleton_method(:active_model!, original)
    end
  end

  def test_describe_component_empty_bounds_returns_null_bbox
    g = Sketchup::Group.new
    g.name = "hollow"
    g.entityID = 5
    g.layer = make_layer("Layer0")
    g.bounds = empty_bbox
    out = M.describe_component(g)
    assert_nil out["bbox_mm"]
    assert_equal 5, out["id"]
    assert_equal "group", out["type"]
    assert_equal "hollow", out["name"]
  end

  def test_describe_component_normal_bounds_unchanged
    g = Sketchup::Group.new
    g.name = "solid"
    g.entityID = 6
    g.layer = make_layer("Layer0")
    g.bounds = Geom::BoundingBox.new(
      Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 1))
    out = M.describe_component(g)
    assert_equal 25.4, out["bbox_mm"]["max"][0]
  end

  def test_single_axis_inversion_is_also_empty
    # P-11: предикат обязан смотреть на ВСЕ оси — инверсия только по y
    # тоже «пусто» (дискриминирует одноосевую реализацию min.x > max.x).
    g = Sketchup::Group.new
    g.name = "y-inverted"
    g.entityID = 7
    g.layer = make_layer("Layer0")
    g.bounds = Geom::BoundingBox.new(
      Geom::Point3d.new(0, SENTINEL, 0), Geom::Point3d.new(1, -SENTINEL, 1))
    out = M.describe_component(g)
    assert_nil out["bbox_mm"]
  end
end
```

Run: `ruby test/test_model_empty_bbox.rb` → RED: первые два теста отдают сентинел-числа вместо nil.

- [ ] **Step 2: GREEN — предикат + `handlers/model.rb`**

2-pre. Предикат в `helpers/geometry.rb` (module `MCPforSketchUp::Helpers::Geometry`), P-11: ЕДИНАЯ точка истины для «пустых» bounds — все три оси, не только x:

```ruby
      # T-55: пустой Geom::BoundingBox SketchUp — «инвертированный» сентинел
      # (min = +1e30 дюймов, max = −1e30 по каждой оси). Проверяем все оси:
      # частичная инверсия — тоже «пусто», одноосевая проверка кодировала бы
      # частный вид сентинела.
      def self.empty_bbox?(bb)
        bb.min.x > bb.max.x || bb.min.y > bb.max.y || bb.min.z > bb.max.z
      end
```

2a. Хелпер (после `describe_component`; в model.rb использовать полный путь `Helpers::Geometry.empty_bbox?` или локальный алиас `HG = MCPforSketchUp::Helpers::Geometry` в шапке модуля — по образцу существующих алиасов):

```ruby
      # T-55: пустые bounds наружу утекали как ±2.54e31 мм и выглядели
      # валидными координатами. Отдаём null.
      def self.bbox_mm_or_nil(bb)
        return nil if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)
        {
          "min" => [U.inch_to_mm(bb.min.x), U.inch_to_mm(bb.min.y), U.inch_to_mm(bb.min.z)],
          "max" => [U.inch_to_mm(bb.max.x), U.inch_to_mm(bb.max.y), U.inch_to_mm(bb.max.z)]
        }
      end
```

⚠ helpers/geometry.rb должен быть в require-цепочке test-файла (добавить `require_relative` хелпера geometry в шапку `test/test_model_empty_bbox.rb`).

2b. `get_model_info`: заменить весь литерал `"bounding_box_mm" => { ... }` (5 строк) на `"bounding_box_mm" => bbox_mm_or_nil(bb),`.

2c. `describe_component`: сразу после `bb = entity.bounds` вставить (через предикат, НЕ inline-условие — P-11):

```ruby
        if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)  # T-55
          return {
            "id"    => entity.entityID,
            "name"  => entity.name,
            "type"  => entity.is_a?(Sketchup::Group) ? "group" : "component",
            "layer" => entity.layer.name,
            "depth" => depth,
            "bbox_mm" => nil
          }
        end
```

- [ ] **Step 3: GREEN — `handlers/geometry.rb::describe_entity`**

Boolean difference может съесть target целиком → пустая группа → тот же сентинел из describe_entity. Заменить тело:

```ruby
      # Returns {id, name, type, bbox_mm} so Claude can re-locate after destructive ops.
      # bbox_mm == nil, если у entity пустые bounds (T-55: инвертированный
      # сентинел SketchUp ±1e30" не должен утекать как ±2.54e31 мм).
      def self.describe_entity(entity)
        bb = entity.bounds
        bbox_mm =
          if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)
            nil
          else
            {
              "min" => [U.inch_to_mm(bb.min.x), U.inch_to_mm(bb.min.y), U.inch_to_mm(bb.min.z)],
              "max" => [U.inch_to_mm(bb.max.x), U.inch_to_mm(bb.max.y), U.inch_to_mm(bb.max.z)]
            }
          end
        {
          "id"   => entity.entityID,
          "name" => entity.name,
          "type" => entity.is_a?(Sketchup::Group) ? "group" : "component",
          "bbox_mm" => bbox_mm
        }
      end
```

NB (P-16, проверено ревью): `describe_entity` НЕ пинится ни одним source-guard-тестом — test_transform_absolute.rb пинит только `position_delta` внутри `transform_component`, test_operation_names.rb — лейблы операций и subtract-паттерны. Прогнать `ruby test/test_transform_absolute.rb` standalone как smoke; правок пинов не ожидается.

- [ ] **Step 4: Прогнать + commit**

```bash
ruby test/test_model_empty_bbox.rb    # 4 runs, 0 failures
ruby test/test_transform_absolute.rb  # standalone smoke: describe_entity не пинится — зелёный без правок
ruby test/run_all.rb                  # 371 runs (367+4), 0 failures
uv run pytest tests/ -q               # 166 passed (Python не задет)
git add mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb test/test_model_empty_bbox.rb
git commit -m "fix: return null instead of 2.54e31 sentinel for empty bounding boxes (T-55)"
```

---

### Task 9: Скриншот — метаданные width/height/preset/style (T-28)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (`get_viewport_screenshot` — возврат)
- Test: `tests/test_screenshot.py`

**Interfaces:**
- Produces: тул возвращает `[Image, str]` — PNG + JSON-строка `{"width", "height", "preset_used", "style_used"}` (Ruby view.rb уже отдаёт эти поля — см. `_ruby_result_for` в test_screenshot.py; обёртка их раньше выбрасывала).
- Consumes: существующий парсинг payload в том же методе.

- [ ] **Step 1: RED — обновить/добавить тесты в `tests/test_screenshot.py`**

1a. `test_screenshot_returns_image` — заменить тело после `with`-блока:

```python
    with _mock_connection(_ruby_result_for(preset="iso", style="shaded")):
        from sketchup_mcp.tools import get_viewport_screenshot
        img, meta_json = await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]

    assert isinstance(img, Image)
    assert img.data == _TINY_PNG_BYTES
    assert img.to_image_content().mimeType == "image/png"
    # T-28: метаданные захвата больше не выбрасываются.
    import json as _json
    meta = _json.loads(meta_json)
    assert meta == {"width": 1, "height": 1,
                    "preset_used": "iso", "style_used": "shaded"}
```

(докстринг теста дополнить: «...and the capture metadata as a JSON text block (T-28)»).

1b. Новый тест после `test_screenshot_via_mcp_dispatch`:

```python
async def test_screenshot_dispatch_includes_metadata_text():
    """T-28: в MCP-конверте рядом с ImageContent едет TextContent с
    width/height/preset_used/style_used — модель может проверить параметры
    захвата, не гадая."""
    import json as _json
    from mcp.types import TextContent
    with _mock_connection(_ruby_result_for(w=800, h=600, preset="iso", style="shaded")):
        import sketchup_mcp.tools  # noqa: F401
        result = await mcp.call_tool("get_viewport_screenshot",
                                     {"view_preset": "iso", "style": "shaded"})
    contents = list(result)
    text_block = next((c for c in contents if isinstance(c, TextContent)), None)
    assert text_block is not None, f"expected TextContent, got {contents!r}"
    meta = _json.loads(text_block.text)
    assert meta["width"] == 800
    assert meta["height"] == 600
    assert meta["preset_used"] == "iso"
    assert meta["style_used"] == "shaded"
```

⚠ В шапке файла уже есть `from sketchup_mcp.app import mcp`.

Run: `uv run pytest tests/test_screenshot.py -q` → RED: unpack `img, meta_json` падает (возвращается одиночный Image); dispatch-тест не находит TextContent.

- [ ] **Step 2: GREEN — конец `get_viewport_screenshot` в tools.py**

Заменить последнюю строку `return Image(data=png_bytes, format="png")` на:

```python
    # T-28: Ruby отдаёт размеры и фактически применённые preset/style —
    # пробрасываем их текстовым блоком рядом с картинкой, чтобы модель могла
    # проверить параметры захвата (а не выбрасываем, как раньше).
    meta = {
        "width": payload.get("width"),
        "height": payload.get("height"),
        "preset_used": payload.get("preset_used"),
        "style_used": payload.get("style_used"),
    }
    return [Image(data=png_bytes, format="png"), json.dumps(meta)]
```

Аннотацию возврата функции сменить с `-> Image:` на `-> list:` (unstructured content path). НЕ `-> list[Image | str]` — проверено пробой на mcp==1.27.0 (P-09 ревью): такая аннотация ПАДАЕТ уже при регистрации тула (pydantic не может построить output-модель из FastMCP `Image`). С голой `-> list` FastMCP конвертирует `Image` → `ImageContent` и голый `str` → `TextContent` автоматически (подтверждено той же пробой: блоки `[ImageContent image/png, TextContent {...}]`) — оборачивать meta в `mcp.types.TextContent` вручную не требуется. Порядок блоков: Image первым, meta-JSON вторым — клиент, показывающий только первый блок, покажет картинку; метаданные вторичны. Состав meta — ровно 4 поля (width/height/preset_used/style_used): это всё, что отдаёт Ruby view.rb.

Обновить докстринг тула: первая строка → «Capture the current SketchUp viewport; returns the PNG image plus a JSON text block {width, height, preset_used, style_used}.»

- [ ] **Step 3: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **168 passed** (167 + 1).

```bash
git add src/sketchup_mcp/tools.py tests/test_screenshot.py
git commit -m "feat: return capture metadata alongside screenshot image (T-28)"
```

### Task 10: server.rb — батч устойчивости ×5 (T-13)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/server.rb`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/client_state.rb`
- Test: `test/test_server_multi_client.rb`

**Interfaces:**
- Consumes: `FakeSocket`/`FakeServer` (`test/support/fake_socket.rb`), `FrameHelpers#fr`/`#all_frames`, `run_one_tick`/`hello_frame` (уже в test_server_multi_client.rb). Framing-ошибки — `StructuredError(-32600)`.
- Produces: `ClientState#close_reason` (accessor), `ClientState#head_frame_remaining` (reader), `ClientState#connected_at` (reader, монотонные секунды); `Server::DISPATCH_MAX_PER_TICK = 50`, `Server::FRAME_QUEUE_SOFT_MAX = 256`, `Server::PRE_HANDSHAKE_DEADLINE_S = 30.0`, приватный `Server#monotonic_now`. `pending_write_deadline_at` теперь хранит **Float (монотонные секунды)**, не Time. Task 14 (T-23) тестирует эти же пути — выполнять ПОСЛЕ этой задачи.

Пять под-фиксов, каждый со своим циклом RED→GREEN→commit. Прогоны: `ruby test/test_server_multi_client.rb` (standalone) + `ruby test/run_all.rb` перед каждым коммитом.

- [ ] **Step 1 (T-13.1) RED — error-envelope не должен теряться при занятом send-буфере**

В `test/test_server_multi_client.rb` добавить:

```ruby
  # ---------- T-13.1: error-envelope переживает занятый send-буфер ----------

  def oversize_header
    [MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 1].pack("N")
  end

  def test_framing_error_envelope_survives_busy_write_buffer
    # Клиент: hello + framing-ошибка (oversize header), при этом первый
    # write_nonblock упирается в WaitWritable. Раньше close_client следовал
    # сразу за send_transport_error — недоставленный envelope умирал вместе
    # с сокетом. Теперь: чтение глушится, закрытие — ПОСЛЕ полного дренажа
    # (механизм close_after_response).
    #
    # NB: hello успел декодироваться ДО ошибочного заголовка, но его ответ
    # НЕ отправляется — process_frame_queue скипает фреймы клиента с
    # close_after_response (стрим рассинхронизирован). Клиент получает
    # ровно один фрейм: error-envelope.
    sock = FakeSocket.new(read_chunks: [hello_frame, oversize_header])
    sock.stub_write_pending(times: 1)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    refute sock.closed?,
      "tick 1: клиент с недоставленным error-envelope не должен быть закрыт"

    srv.send(:on_timer_tick)   # tick 2: буфер дренируется → закрытие
    assert sock.closed?, "tick 2: после доставки envelope клиент закрывается"
    frames = all_frames(sock.written)
    assert_equal 1, frames.size, "ровно один фрейм — error-envelope"
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_nil frames[0]["id"]
  end

  def test_parse_error_envelope_survives_busy_write_buffer
    # Здесь оба фрейма ДЕКОДИРУЮТСЯ (framing цел), hello диспатчится до
    # ошибки → его ответ тоже в буфере. Бюджет WaitWritable = 2: первый
    # флаш hello-ответа и флаш error-envelope оба упираются в занятый
    # буфер, tick 2 дренирует всё разом.
    garbage = "not json at all"
    bad_frame = [garbage.bytesize].pack("N") + garbage
    sock = FakeSocket.new(read_chunks: [hello_frame, bad_frame])
    sock.stub_write_pending(times: 2)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    refute sock.closed?, "tick 1: envelope ещё в буфере — не закрывать"
    srv.send(:on_timer_tick)
    assert sock.closed?
    frames = all_frames(sock.written)
    assert_equal 2, frames.size, "hello-ответ + parse-error envelope"
    assert_equal 0, frames[0]["id"]
    assert_equal(-32700, frames.last["error"]["code"])
  end
```

Run: `ruby test/test_server_multi_client.rb` → оба FAIL на `refute sock.closed?` tick 1 (текущий код закрывает клиента сразу, до дренажа envelope).

- [ ] **Step 2 (T-13.1) GREEN**

2a. `client_state.rb`: в `attr_accessor` добавить `:close_reason`; в `initialize` — `@close_reason = nil`.

2b. `server.rb`, `drain_one_client`: сразу после `return if state.closed?` добавить:

```ruby
        # T-13.1: решение о закрытии принято (framing/parse-ошибка) — стрим
        # рассинхронизирован, новые чтения бессмысленны до close-after-drain.
        return if state.close_after_response
```

2c. `drain_one_client`, ветка `rescue StructuredError => e` — заменить:

```ruby
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream desynced.
        send_transport_error(state, e, nil)
        close_client(state, "framing_error: #{e.message}")
```

на:

```ruby
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream desynced. T-13.1:
        # НЕ закрывать сразу — при занятом send-буфере error-envelope молча
        # терялся. Глушим чтение (guard выше), закрываемся после полного
        # дренажа буфера — механизм close_after_response, как у
        # reject_handshake.
        state.close_reason = "framing_error: #{e.message}"
        state.close_after_response = true
        send_transport_error(state, e, nil)
```

2d. `handle_frame`, ветка `rescue JSON::ParserError => e` — заменить `send_transport_error(...)` + `close_client(state, "parse_error")` на:

```ruby
        state.close_reason = "parse_error"
        state.close_after_response = true
        send_transport_error(state,
          StructuredError.new(-32700, "parse error: #{e.message}"), nil)
```

(строка `nil` в конце ветки остаётся).

2e. `process_frame_queue`: строку `next if state.closed?` заменить на `next if state.closed? || state.close_after_response` (уже декодированные фреймы рассинхронизированного клиента не диспатчим).

2f. `flush_pending_write`: строку `close_client(state, "handshake_rejected")` заменить на `close_client(state, state.close_reason || "handshake_rejected")`.

Run: `ruby test/test_server_multi_client.rb` → 0 failures. `ruby test/run_all.rb` → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb mcp_for_sketchup/mcp_for_sketchup/core/client_state.rb test/test_server_multi_client.rb
git commit -m "fix: deliver error envelope before closing client on framing/parse errors (T-13.1)"
```

- [ ] **Step 3 (T-13.2) RED — кап диспатча за тик + backpressure очереди**

```ruby
  # ---------- T-13.2: кап диспатча/тик + backpressure ----------

  def gv_frame(id)
    fr("jsonrpc" => "2.0", "method" => "tools/call",
       "params" => { "name" => "get_version", "arguments" => {} },
       "id" => id)
  end

  def test_dispatch_capped_per_tick_preserving_fifo
    # 1 hello + 60 запросов одним chunk'ом: раньше все 61 диспатчились за
    # один тик (флуд мелких фреймов морозит UI SketchUp). Теперь — не больше
    # DISPATCH_MAX_PER_TICK за тик, остаток уходит на следующий, FIFO цел.
    payload = hello_frame + (1..60).map { |i| gv_frame(i) }.join
    sock = FakeSocket.new(read_chunks: [payload])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    cap = MCPforSketchUp::Core::Server::DISPATCH_MAX_PER_TICK
    tick1 = all_frames(sock.written)
    assert_equal cap, tick1.size,
      "tick 1 обязан диспатчить ровно DISPATCH_MAX_PER_TICK (#{cap}) фреймов"

    srv.send(:on_timer_tick)
    tick2 = all_frames(sock.written)
    assert_equal 61, tick2.size, "tick 2 дорабатывает остаток"
    assert_equal [0] + (1..60).to_a, tick2.map { |f| f["id"] }, "FIFO сохранён"
  end

  def test_read_backpressure_when_frame_queue_saturated
    # Очередь фреймов забита (>= FRAME_QUEUE_SOFT_MAX) — новые чтения из
    # сокетов откладываются (kernel-буфер удержит данные, TCP даст естественный
    # backpressure). Раньше чтение продолжалось без ограничений.
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    dead = FakeSocket.new
    dead.close
    dummy = MCPforSketchUp::Core::ClientState.new(999, dead)
    soft_max = MCPforSketchUp::Core::Server::FRAME_QUEUE_SOFT_MAX
    srv.instance_variable_set(:@frame_queue, Array.new(soft_max) { [dummy, "{}"] })

    srv.send(:on_timer_tick)
    assert_equal "", sock.written.b,
      "tick 1: при забитой очереди клиента читать нельзя — hello не должен быть обработан"

    srv.send(:on_timer_tick)   # очередь освободилась (закрытые dummy-фреймы скипнуты)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size, "tick 2: hello обработан после разгрузки очереди"
    assert_equal 0, frames[0]["id"]
  end

  def test_flood_stops_reading_mid_drain_once_queue_saturated
    # P-06 (ревью): guard только на ВХОДЕ в фазу чтения недостаточен — один
    # клиент за один тик мог накачать очередь сильно выше SOFT_MAX. Чтение
    # обязано останавливаться и ПОСРЕДИ дренажа: второй chunk не читается,
    # когда первый уже насытил очередь.
    soft_max = MCPforSketchUp::Core::Server::FRAME_QUEUE_SOFT_MAX
    flood = (1..(soft_max + 50)).map { |i| gv_frame(i) }.join
    marker = gv_frame(99_999)
    sock = FakeSocket.new(read_chunks: [hello_frame + flood, marker])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    queue_ids = srv.instance_variable_get(:@frame_queue)
                   .map { |_st, body| JSON.parse(body)["id"] }
    answered_ids = all_frames(sock.written).map { |f| f["id"] }
    refute_includes queue_ids + answered_ids, 99_999,
      "marker-фрейм из второго chunk не должен быть прочитан: очередь насыщена первым"
  end
```

Run → три FAIL (у первых двух константы не определены → NameError; у flood-теста marker прочитан — внутреннего guard'а нет). ⚠ flood-тест опирается на то, что FakeSocket отдаёт read_chunks по одному куску на read_nonblock — сверить с test/support/fake_socket.rb и при необходимости адаптировать раскладку чанков, не меняя сути (второй кусок обязан остаться непрочитанным).

- [ ] **Step 4 (T-13.2) GREEN**

4a. Константы в шапку `Server` (после `MAX_CLIENTS`):

```ruby
      # T-13.2: связка капов (M-08 ревью). Чтение (READ_MAX_ITERATIONS=50
      # НА КЛИЕНТА) может опережать глобальный диспатч (50 НА ТИК); при
      # TIMER_INTERVAL 0.1 с потолок ~500 диспатчей/с — за глаза для
      # односкетчаповых нагрузок. Разница поглощается очередью до
      # FRAME_QUEUE_SOFT_MAX (~5 тиков разгрузки), дальше чтение
      # приостанавливается и TCP-окно передаёт backpressure клиенту.
      # Стоп чтения ГЛОБАЛЬНЫЙ (все сокеты) — осознанно: очередь одна,
      # FIFO-порядок важнее fairness чтения; kernel-буферы данные удержат.
      DISPATCH_MAX_PER_TICK     = 50      # фреймов за тик; флуд мелких фреймов не должен морозить UI (T-13.2)
      FRAME_QUEUE_SOFT_MAX      = 256     # очередь насыщена — чтение приостанавливается (T-13.2, P-06)
```

4b. `drain_reads_all_clients` — первой строкой:

```ruby
        # T-13.2: backpressure. Очередь и так забита — оставляем данные в
        # kernel-буфере (TCP-окно заполнится, клиент притормозит сам). FIFO
        # не страдает: недочитанное придёт в том же порядке следующим тиком.
        return if @frame_queue.length >= FRAME_QUEUE_SOFT_MAX
```

4b-bis (P-06 ревью): входного guard'а недостаточно — один клиент за один
тик может накачать очередь сильно выше SOFT_MAX (до READ_MAX_ITERATIONS
кусков по 64 KiB мелких фреймов). В `drain_one_client`, в read-цикле, СРАЗУ
после блока, где декодированные из очередного `read_nonblock` фреймы
кладутся в `@frame_queue`, добавить:

```ruby
          # P-06: стоп посреди дренажа, как только очередь насыщена; перелёт
          # ограничен фреймами ОДНОГО read_nonblock-куска (≤64 KiB), а не
          # всем бюджетом READ_MAX_ITERATIONS.
          break if @frame_queue.length >= FRAME_QUEUE_SOFT_MAX
```

4c. `process_frame_queue` — заменить целиком:

```ruby
      def process_frame_queue
        dispatched = 0
        until @frame_queue.empty?
          # T-13.2: кап на тик. shift с головы + return сохраняют FIFO —
          # остаток обрабатывается следующим тиком, UI SketchUp дышит.
          return if dispatched >= DISPATCH_MAX_PER_TICK
          state, body = @frame_queue.shift
          next if state.closed? || state.close_after_response

          response = handle_frame(state, body)
          if response
            write_response(state, response)
          end
          dispatched += 1
        end
      end
```

Run: standalone + run_all → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb test/test_server_multi_client.rb
git commit -m "fix: cap frame dispatch per tick and add read backpressure (T-13.2)"
```

- [ ] **Step 5 (T-13.3) RED — overflow-guard не должен приговаривать клиента за дренирующийся большой head-фрейм**

```ruby
  # ---------- T-13.3: overflow-guard считает хвост, не head-фрейм ----------

  # P-15 (решение ревью): временная подмена константы через remove_const/
  # const_set принята ОСОЗНАННО — ensure выполняется и при упавшем ассерте
  # (Minitest::Assertion — обычное исключение), пара remove+set не генерирует
  # warning; альтернатива (аксессор в проде ради теста) отклонена.
  def with_pending_write_cap(bytes)
    srv_class = MCPforSketchUp::Core::Server
    original = srv_class::PENDING_WRITE_MAX_BYTES
    srv_class.send(:remove_const, :PENDING_WRITE_MAX_BYTES)
    srv_class.const_set(:PENDING_WRITE_MAX_BYTES, bytes)
    yield
  ensure
    srv_class.send(:remove_const, :PENDING_WRITE_MAX_BYTES)
    srv_class.const_set(:PENDING_WRITE_MAX_BYTES, original)
  end

  def response_of_size(id, target_bytes)
    pad = "x" * target_bytes
    { "jsonrpc" => "2.0", "result" => { "pad" => pad }, "id" => id }
  end

  def test_overflow_guard_ignores_draining_head_frame
    with_pending_write_cap(400) do
      sock = FakeSocket.new
      # Head-фрейм уйдёт в буфер целиком; дренаж — по 10 байт за вызов,
      # бюджет 1 вызов на тик (дальше WaitWritable) → head «дренируется» долго.
      sock.stub_partial_write(max_bytes_per_call: 10, calls: 1)
      state = MCPforSketchUp::Core::ClientState.new(0, sock)
      srv = MCPforSketchUp::Core::Server.new
      srv.instance_variable_get(:@clients)[sock] = state

      # 1) Большой head (≈600 байт > cap 400) допущен на ПУСТОЙ буфер.
      srv.send(:write_response, state, response_of_size(1, 550))
      refute sock.closed?, "head-фрейм на пустой буфер допускается всегда"

      # 2) Малый фрейм при недодренированном head: раньше backlog>0 и
      #    projected>cap закрывали клиента. Теперь хвост (без head) = 0+small.
      srv.send(:write_response, state, response_of_size(2, 50))
      refute sock.closed?,
        "малый фрейм за большим head не должен приговаривать клиента (T-13.3)"

      # 3) Патологическое накопление ХВОСТА за head'ом всё ещё режется капом.
      srv.send(:write_response, state, response_of_size(3, 550))
      assert sock.closed?, "хвост сверх капа — закрытие остаётся в силе"
    end
  end

  def test_client_state_tracks_head_frame_remaining
    sock = FakeSocket.new
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    state.append_pending_write("A" * 100)     # head на пустой буфер
    assert_equal 100, state.head_frame_remaining
    state.append_pending_write("B" * 40)      # хвост head не трогает
    assert_equal 100, state.head_frame_remaining
    state.consume_pending_write(60)
    assert_equal 40, state.head_frame_remaining
    state.consume_pending_write(60)           # head дожат (40) + 20 из хвоста
    assert_equal 0, state.head_frame_remaining
  end
```

Run → FAIL (`head_frame_remaining` не определён; клиент закрывается на шаге 2).

- [ ] **Step 6 (T-13.3) GREEN**

6a. `client_state.rb`: в `attr_reader` добавить `:head_frame_remaining`; в `initialize` — `@head_frame_remaining = 0`; заменить `append_pending_write`/`consume_pending_write`:

```ruby
      # Append bytes to the pending-write buffer. Always coerced to ASCII_8BIT
      # so concatenation with other binary frames cannot trigger an encoding
      # error. Returns the new buffer size.
      #
      # T-13.3: фрейм, лёгший на ПУСТОЙ буфер, становится head'ом — его размер
      # запоминается, чтобы overflow-guard сервера применял кап только к
      # хвосту за ним (head уже ограничен framing-капом 64 MiB).
      def append_pending_write(bytes)
        payload = bytes.b
        @head_frame_remaining = payload.bytesize if @pending_write_bytes.bytesize == 0
        @pending_write_bytes << payload
        @pending_write_bytes.bytesize
      end

      # Drop the leading `n` bytes from the pending-write buffer (after a
      # successful partial write_nonblock). Re-allocates in ASCII_8BIT so
      # subsequent appends keep the binary encoding invariant.
      def consume_pending_write(n)
        return if n <= 0
        consumed_from_head = [n, @head_frame_remaining].min
        @head_frame_remaining -= consumed_from_head
        if n >= @pending_write_bytes.bytesize
          @pending_write_bytes = String.new(encoding: Encoding::ASCII_8BIT)
        else
          rest = @pending_write_bytes.byteslice(n..-1) ||
                 String.new(encoding: Encoding::ASCII_8BIT)
          @pending_write_bytes = String.new(rest, encoding: Encoding::ASCII_8BIT)
        end
      end
```

6b. `server.rb`, `write_response` — заменить overflow-блок (от `backlog   = state.pending_write_bytes.bytesize` до `end` перед `state.append_pending_write(frame)`):

```ruby
        # Overflow guard (T-13.3): кап применяется к ХВОСТУ за пределами ещё
        # дренирующегося head-фрейма. Head, допущенный на пустой буфер, уже
        # ограничен framing-капом (64 MiB) и не приговаривает клиента: раньше
        # один легитимный >16 MiB ответ (например ~43 MiB скриншот) плюс ЛЮБОЙ
        # следующий фрейм закрывали соединение. Патологическое накопление
        # хвоста по-прежнему режется.
        backlog      = state.pending_write_bytes.bytesize
        tail_backlog = backlog - state.head_frame_remaining
        projected    = tail_backlog + frame.bytesize
        if backlog > 0 && projected > PENDING_WRITE_MAX_BYTES
          Logger.log_tool("server", "pending_write_overflow",
            "limit=#{PENDING_WRITE_MAX_BYTES} projected_tail=#{projected} backlog=#{backlog}",
            client_label: state.label)
          close_client(state, "pending_write_overflow")
          return
        end
```

⚠ **P-17 (ревью, подтверждено тремя источниками): существующий `test_pending_write_overflow_closes_client` (test_server_multi_client.rb:~407) под новой семантикой СТАНЕТ КРАСНЫМ** — он кладёт `near = "x" * (cap - 64)` прямым `append_pending_write` на ПУСТОЙ буфер, и после T-13.3 эти байты становятся head-фреймом (`tail_backlog = 0`, projected ≈ размер малого фрейма << cap → guard молчит → `assert sock.closed?` падает). Переработать его В ЭТОМ ЖЕ коммите: вставить ПЕРЕД набивкой `near` строку `state.append_pending_write("h" * 8)` (малый head; `near` не менять) — тогда `near` становится ХВОСТОМ (`tail_backlog = cap - 64`), и граница срабатывания остаётся прежней (малый фрейм > 64 байт переполняет), тест сохраняет смысл «хвост сверх капа приговаривает». Зафиксировать переработку в commit message.

Run: standalone + run_all → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb mcp_for_sketchup/mcp_for_sketchup/core/client_state.rb test/test_server_multi_client.rb
git commit -m "fix: exempt draining head frame from pending-write overflow cap (T-13.3)"
```

- [ ] **Step 7 (T-13.4) RED+GREEN — монотонные часы в write-deadline**

7a. RED-тест:

```ruby
  # ---------- T-13.4: write-deadline на монотонных часах ----------

  def test_write_deadline_uses_monotonic_clock
    # Wall-clock Time.now прыгает (NTP-коррекция, перевод часов) — idle-дедлайн
    # на нём ложно закрывает/вечно держит клиента. Монотонные секунды — Float.
    sock = FakeSocket.new
    sock.stub_write_pending(times: 1)
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_get(:@clients)[sock] = state
    srv.send(:write_response, state, response_of_size(1, 10))
    assert_kind_of Float, state.pending_write_deadline_at,
      "deadline должен быть монотонным Float, а не Time"
  end
```

Run → FAIL (`Time` не `Float`).

7b. GREEN — в `server.rb`:

- приватный хелпер (рядом с `loopback_host?`):

```ruby
      # T-13.4: все дедлайны — на монотонных часах; wall-clock (Time.now)
      # прыгает при NTP-коррекции и переводе времени.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
```

- три замены `Time.now` → `monotonic_now` (в `write_response`: `state.pending_write_deadline_at = monotonic_now + WRITE_DEADLINE_S`; в `flush_pending_write`: `monotonic_now > state.pending_write_deadline_at` и `state.pending_write_deadline_at = monotonic_now + WRITE_DEADLINE_S`).

7c. Обновить ТРИ существующих теста, задающих дедлайн wall-clock'ом (`grep -n "Time.now" test/test_server_multi_client.rb`): строки вида `state.pending_write_deadline_at = Time.now - 1.0` / `Time.now + 60` / `original_deadline = Time.now + 0.5` заменить на `Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0` / `+ 60` / `+ 0.5` соответственно (сравнение `assert_operator ... :>, original_deadline` продолжает работать на Float).

Run: standalone + run_all → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb test/test_server_multi_client.rb
git commit -m "fix: use monotonic clock for pending-write idle deadline (T-13.4)"
```

- [ ] **Step 8 (T-13.5) RED — pre-handshake дедлайн**

```ruby
  # ---------- T-13.5: pre-handshake дедлайн ----------

  def test_silent_pre_handshake_client_closed_after_deadline
    # 64 молчаливых коннекта (без hello) навсегда исчерпывали MAX_CLIENTS —
    # DoS на exposed-bind. Не завершившие handshake за PRE_HANDSHAKE_DEADLINE_S
    # закрываются.
    sock = FakeSocket.new   # молчит: ни hello, ни байта
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    state = srv.instance_variable_get(:@clients)[sock]
    refute_nil state, "клиент зарегистрирован"
    refute sock.closed?, "свежий клиент жив"

    # Состариваем подключение за дедлайн.
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)
    assert sock.closed?, "молчаливый pre-handshake клиент закрыт по дедлайну"
    refute srv.instance_variable_get(:@clients).key?(sock)
  end

  def test_handshaked_client_not_touched_by_pre_handshake_deadline
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    state = srv.instance_variable_get(:@clients)[sock]
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)
    refute sock.closed?, "handshake завершён — дедлайн не применяется"
  end

  def test_pre_handshake_sweep_spares_client_draining_reject_envelope
    # P-07 (ревью): клиент с framing-error-envelope в pending-write
    # (close_after_response, T-13.1) закрывается механизмом close-after-drain
    # со СВОИМ дедлайном (WRITE_DEADLINE_S) — pre-handshake свип не должен
    # убивать его раньше доставки envelope.
    sock = FakeSocket.new(read_chunks: [oversize_header])
    sock.stub_write_pending(times: 1)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)   # framing-ошибка → envelope в буфере, close_after_response
    state = srv.instance_variable_get(:@clients)[sock]
    refute_nil state, "клиент ещё жив: envelope не доставлен"
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)   # свип обязан пропустить; дренаж доставит envelope
    frames = all_frames(sock.written)
    assert_equal 1, frames.size,
      "error-envelope обязан быть доставлен, а не срезан pre-handshake свипом"
    assert_equal(-32600, frames[0]["error"]["code"])
  end
```

Run → FAIL (`connected_at` не определён; sweep-тест дополнительно падает без skip-ветки — свип закрывает клиента до дренажа, frames пуст).

- [ ] **Step 9 (T-13.5) GREEN**

9a. `client_state.rb`: в `attr_reader` добавить `:connected_at`; в `initialize`:

```ruby
        # T-13.5: монотонная отметка подключения — pre-handshake дедлайн.
        @connected_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
```

9b. `server.rb`: константа `PRE_HANDSHAKE_DEADLINE_S = 30.0` в шапку (после `FRAME_QUEUE_SOFT_MAX`); в `on_timer_tick` после `accept_pending_clients` вставить `close_pre_handshake_stragglers`; приватный метод (рядом с `accept_pending_clients`):

```ruby
      # T-13.5: коннект, не приславший валидный hello за
      # PRE_HANDSHAKE_DEADLINE_S, закрывается. Без этого 64 молчаливых
      # TCP-коннекта навсегда исчерпывают слоты MAX_CLIENTS (DoS при
      # exposed-bind; до дедлайна слоты, естественно, заняты — 30 с и есть
      # граница этой уязвимости). 30 с заведомо щедро: hello уходит первым
      # же фреймом сразу после connect(), даже WAN-RTT на порядки меньше.
      # Wire-протокол не меняется — это чисто серверный таймер.
      def close_pre_handshake_stragglers
        now = monotonic_now
        @clients.values.each do |state|
          next if state.handshaked
          # P-07: клиент с reject/error-envelope в буфере доживает до
          # доставки — его закроет close-after-drain (свой WRITE_DEADLINE_S).
          next if state.close_after_response
          next if now - state.connected_at < PRE_HANDSHAKE_DEADLINE_S
          Logger.log_tool("server", "pre_handshake_timeout",
            client_label: state.label)
          close_client(state, "pre_handshake_timeout")
        end
      end
```

Run: `ruby test/test_server_multi_client.rb && ruby test/test_state_machine.rb && ruby test/test_server_handshake.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/server.rb mcp_for_sketchup/mcp_for_sketchup/core/client_state.rb test/test_server_multi_client.rb
git commit -m "fix: close clients that never complete the hello handshake (T-13.5)"
```

---

### Task 11: Ruby-мелочь — compat-сообщение, OBJ-ключ, Logger-guard, export-warning (T-14 + T-15 + T-19 + T-27)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`msg_python_too_new`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb` (`export_obj`, `export`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/config.rb` (2 × `defined?(Logger)`)
- Test: `test/test_compat.rb`, `test/test_export_skp.rb`, `test/test_export_options.rb` (новый), `test/test_config_logger_guard.rb` (новый)

Четыре независимых мини-цикла; коммит после каждого.

- [ ] **Step 1 (T-14): compat-сообщение «переустановите то, что уже стоит»**

1a. RED — в `test/test_compat.rb::test_too_new_raises_with_reinstall_hint` добавить ассерты (после `assert_includes err.message, ".rbz"`). Заодно (M-15c) переименовать тест в `test_too_new_points_forward_and_backward` — прежнее имя «reinstall hint» после фикса вводило бы в заблуждение (суть меняется на «НЕ reinstall той же версии»):

```ruby
      assert_includes err.message, "sketchup-mcp2==0.2.0",
        "должен предлагать откат клиента на поддерживаемую версию"
      assert_includes err.message, "newer plugin",
        "должен указывать вперёд — на более новый .rbz, если он существует"
```

⚠ `with_range("0.1.0", "0.2.0")` в этом тесте подменяет MAX_PYTHON на "0.2.0" — интерполяция в сообщении даст `sketchup-mcp2==0.2.0`.

Run: `ruby test/test_compat.rb` → 1 FAIL (нет таких подстрок).

1b. GREEN — в `core/compat.rb` заменить `msg_python_too_new`:

```ruby
      def self.msg_python_too_new(cv)
        # T-14: MAX_PYTHON == SERVER_VERSION, поэтому прежний совет
        # «Reinstall …v#{MAX_PYTHON}…» предлагал переустановить уже
        # установленную версию плагина. Указываем в обе стороны.
        "sketchup-mcp2 v#{cv} is newer than SketchUp plugin v#{SERVER_VERSION} " \
        "supports (max v#{MAX_PYTHON}). Handshake rejected. " \
        "Either install a newer plugin .rbz from the GitHub releases page " \
        "(if one exists for v#{cv}), or downgrade the client: " \
        "uv pip install sketchup-mcp2==#{MAX_PYTHON}. " \
        "Call `get_version` to inspect handshake state."
      end
```

1c. Run: `ruby test/test_compat.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/compat.rb test/test_compat.rb
git commit -m "fix: msg_python_too_new no longer suggests reinstalling the same plugin version (T-14)"
```

- [ ] **Step 2 (T-15): опечатка ключа OBJ-экспортёра**

2a. RED — новый файл `test/test_export_options.rb`:

```ruby
# test/test_export_options.rb
# T-15: ключи exporter-хешей SketchUp строго именованы; неизвестный ключ
# МОЛЧА игнорируется. Официальный ключ OBJ — :doublesided_faces (без
# подчёркивания между double и sided); double_sided_faces тихо терял опцию.
require "minitest/autorun"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/export"

class TestExportOptions < Minitest::Test
  X = MCPforSketchUp::Handlers::Export

  class OptionsCapture
    attr_reader :last_path, :last_options
    def export(path, options)
      @last_path = path
      @last_options = options
      true
    end
  end

  def test_obj_uses_official_doublesided_faces_key
    model = OptionsCapture.new
    X.export_obj(model, "/tmp/x.obj")
    assert model.last_options.key?(:doublesided_faces),
      "официальный ключ OBJ-экспортёра — :doublesided_faces"
    refute model.last_options.key?(:double_sided_faces),
      "опечатанный ключ должен исчезнуть (SketchUp его молча игнорировал)"
    assert_equal true, model.last_options[:doublesided_faces]
    # M-03 (ревью): полный пин фактического obj-хеша — прочитать export_obj
    # перед правкой и зафиксировать ВСЕ его ключи официальными именами
    # (например { triangulated_faces: ..., doublesided_faces: true,
    # edges: ..., texture_maps: ... } — состав взять из кода, не из этого
    # комментария); неизвестный ключ SketchUp игнорирует МОЛЧА.
    # assert_equal <полный фактический хеш>, model.last_options
  end

  def test_other_export_hashes_unchanged
    model = OptionsCapture.new
    X.export_dae(model, "/tmp/x.dae")
    assert_equal({ triangulated_faces: true }, model.last_options)
    X.export_stl(model, "/tmp/x.stl")
    assert_equal({ units: "model" }, model.last_options)
  end
end
```

Run: `ruby test/test_export_options.rb` → FAIL (ключ с опечаткой).

2b. GREEN — в `handlers/export.rb::export_obj` заменить `double_sided_faces:  true,` на:

```ruby
          doublesided_faces:   true,   # T-15: официальное имя ключа (double_sided_faces молча игнорировался)
```

2c. Сверка остальных хешей (уже пин-тестом): dae `triangulated_faces` и stl `units: "model"` соответствуют официальным таблицам опций экспортёров SketchUp; png/jpg идут через `view.write_image` (другой API, ключи filename/width/height/antialias/transparent — верны).

2d. Run: `ruby test/test_export_options.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb test/test_export_options.rb
git commit -m "fix: OBJ exporter option key doublesided_faces (typo silently ignored) (T-15)"
```

- [ ] **Step 3 (T-19): `defined?(Logger)` может схватить stdlib `::Logger`**

3a. RED — новый файл `test/test_config_logger_guard.rb`:

```ruby
# test/test_config_logger_guard.rb
# T-19: config.rb может исполняться ДО загрузки core/logger (ранний бут,
# точечный require в тестах). Если при этом кто-то в общем интерпретаторе
# SketchUp сделал require "logger", то defined?(Logger) находил stdlib
# ::Logger, и диагностический fallback падал NoMethodError (у stdlib Logger
# нет класс-метода .log) — ломая ровно тот путь, который защищал.
# Standalone-прогон этого файла дискриминирует баг (core/logger НЕ
# загружен); под run_all Core::Logger уже загружен — тест остаётся
# smoke-пином fallback-пути.
require "minitest/autorun"
require "logger"   # stdlib — имитация чужого require в shared-интерпретаторе

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"

class TestConfigLoggerGuard < Minitest::Test
  class PrefReader
    def read_default(_section, key, default = nil)
      key == "port" ? "not-a-port" : default
    end
  end

  def test_invalid_pref_fallback_survives_stdlib_logger_in_namespace
    MCPforSketchUp::Core::Config.load_from_defaults!(PrefReader.new)
    assert_equal 9876, MCPforSketchUp::Core::Config.port,
      "невалидный pref обязан откатиться к дефолту без исключения"
  end
end
```

Run: `ruby test/test_config_logger_guard.rb` → FAIL standalone (NoMethodError: undefined method 'log' for class Logger).

3b. GREEN — в `core/config.rb` две замены `if defined?(Logger)` → `if defined?(Core::Logger)` (в `coerce_bool_pref` и `warn_invalid_pref`); в комментарии над первой добавить: `# T-19: именно Core::Logger — голое defined?(Logger) находило stdlib ::Logger (паттерн client_state.rb).`

3c. Run: `ruby test/test_config_logger_guard.rb && ruby test/test_config.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/config.rb test/test_config_logger_guard.rb
git commit -m "fix: guard against stdlib ::Logger capture in config fallback logging (T-19)"
```

- [ ] **Step 4 (T-27): export(skp) на untitled-модели — поле warning**

4a. RED — в `test/test_export_skp.rb` добавить тесты (в конец класса; для вызова `X.export` нужны стабы `V`/`E` — файл определяет их пустыми, поэтому стабим методы с восстановлением):

```ruby
  def with_export_stubs(model)
    v = MCPforSketchUp::Helpers::Validation
    e = MCPforSketchUp::Helpers::Entities
    orig_enum  = v.respond_to?(:require_enum)  ? v.method(:require_enum)  : nil
    orig_model = e.respond_to?(:active_model!) ? e.method(:active_model!) : nil
    v.define_singleton_method(:require_enum) { |params, key, _allowed| params[key] }
    e.define_singleton_method(:active_model!) { model }
    yield
  ensure
    if orig_enum
      v.define_singleton_method(:require_enum, orig_enum)
    else
      v.singleton_class.send(:remove_method, :require_enum)
    end
    if orig_model
      e.define_singleton_method(:active_model!, orig_model)
    else
      e.singleton_class.send(:remove_method, :active_model!)
    end
  end

  def test_untitled_skp_export_carries_warning
    model = FakeModel.new("")
    result = with_export_stubs(model) { X.export({ "format" => "skp" }) }
    assert_includes result.keys, "warning",
      "T-27: save на untitled-модели привязывает документ к temp-пути — LLM обязан узнать"
    assert_match(/untitled/i, result["warning"])
    assert_match(/Ctrl\+S|next save/i, result["warning"])
  end

  def test_titled_skp_export_has_no_warning
    model = FakeModel.new("/home/user/model.skp")
    result = with_export_stubs(model) { X.export({ "format" => "skp" }) }
    refute result.key?("warning")
  end
```

⚠ P-02 (ревью): под run_all `Validation`/`Entities` — реальные модули, и их `def self.`-методы — это УЖЕ singleton-методы. `define_singleton_method` их ПЕРЕЗАПИСЫВАЕТ (не «кладёт поверх»), а голый `remove_method` в ensure удалил бы реальный метод НАСОВСЕМ — все последующие тесты сессии потеряли бы `V.require_enum`/`E.active_model!`. Поэтому — паттерн «сохранить Method и восстановить» (эталон test_collect_components.rb); ветка remove_method остаётся только для standalone-прогона, где модули пустые (их объявляет шапка этого же файла — сверить при исполнении, deepseek CI-4).

Run: `ruby test/test_export_skp.rb` → 2 FAIL (нет warning; untitled-тест может упасть и на FakeModel — see 4b).

4b. GREEN — в `handlers/export.rb::export`:

- после строки `export_path = build_export_path(format)` добавить:

```ruby
        # T-27: save на untitled-модели ПРИВЯЗЫВАЕТ живой документ к temp-пути
        # (следующий Ctrl+S пользователя молча уйдёт туда). Сам выбор save
        # задуман (см. save_skp) — но LLM обязан получить предупреждение
        # и передать его пользователю.
        skp_untitled = format == "skp" && model.path.to_s.empty?
```

- заменить финальную строку `{ "path" => export_path, "format" => format }` на:

```ruby
        result = { "path" => export_path, "format" => format }
        if skp_untitled
          result["warning"] =
            "model was untitled: SketchUp bound the live document to the export " \
            "path (#{export_path}); the user's next save (Ctrl+S) will write there. " \
            "Tell the user to Save As their intended location if that is not desired."
        end
        result
```

4c. Run: `ruby test/test_export_skp.rb && ruby test/run_all.rb` → 0 failures. ⚠ `build_export_path` создаёт каталог в tmpdir — это допустимый side-effect теста (каталог переиспользуемый).

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb test/test_export_skp.rb
git commit -m "feat: warn when skp export binds an untitled model to the temp path (T-27)"
```

### Task 12: make_unique перед мутацией definition-entities (T-16)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb` (новый `mutable_entity_collection`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/materials.rb` (`apply_to_entity`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` (`place_tenon`, `add_parent_frame_prototype`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb` (`run_edge_op`, строка `target_entities = E.entity_collection(entity)`)
- Test: `test/test_entities_unique.rb` (новый)

**Interfaces:**
- Produces: `E.mutable_entity_collection(entity)` — `make_unique` (если метод есть) + `entity_collection`. МУТИРУЮЩИЕ call-sites переключаются на него; read-only обходы (`model.rb:83`, `operations.rb` строка `cur_edges = ...` — читает уже-уникальный entity) остаются на `entity_collection`.
- Consumes: `E.entity_collection` — без изменений.
- ⚠ Поведенческое изменение: покраска/резьба/чамфер одного инстанса больше НЕ задевает другие инстансы той же definition. Докстринги обновит Task 15.
- Граница скоупа (C-10, решение ревью): subtract-пути (`boolean_operation`, `place_mortise`/carve-цепочки) в make_unique НЕ нуждаются — `Group#subtract` не мутирует definition in-place, а ПОТРЕБЛЯЕТ входы и создаёт новую группу-результат; остальные инстансы шаренной definition не затрагиваются по построению. Это API-семантика SketchUp, юнит-фейками не проверяемая — пункт добавлен в ручной live-smoke владельца (см. «После плана»).

- [ ] **Step 1: RED — новый файл `test/test_entities_unique.rb`**

```ruby
# test/test_entities_unique.rb
# T-16: entity_collection у ComponentInstance отдаёт definition.entities —
# ШАРИТСЯ между инстансами. Мутация через неё красит/режет ВСЕ инстансы
# («четыре стула краснеют разом»). Мутирующие пути обязаны идти через
# mutable_entity_collection (= make_unique + entity_collection).
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"

class TestEntitiesUnique < Minitest::Test
  E = MCPforSketchUp::Helpers::Entities

  FakeDefinition = Struct.new(:entities)

  class FakeInstance < Sketchup::ComponentInstance
    attr_reader :definition, :make_unique_calls
    def initialize(definition)
      @definition = definition
      @make_unique_calls = 0
    end
    def make_unique
      # Реальный SketchUp: инстанс отвязывается в СОБСТВЕННУЮ копию definition.
      @make_unique_calls += 1
      @definition = FakeDefinition.new(@definition.entities.dup)
      self
    end
  end

  class FakePlainGroup < Sketchup::Group
    attr_reader :entities
    def initialize
      @entities = [:g]
    end
    # namely: без make_unique — guard respond_to? обязан не падать
  end

  def test_mutable_collection_makes_instance_unique_first
    shared = FakeDefinition.new([:shared_face])
    inst_a = FakeInstance.new(shared)
    inst_b = FakeInstance.new(shared)

    coll = E.mutable_entity_collection(inst_a)

    assert_equal 1, inst_a.make_unique_calls, "make_unique обязан быть вызван до мутации"
    refute_same shared.entities, coll,
      "мутируемая коллекция должна принадлежать УНИКАЛЬНОЙ definition"
    assert_same shared, inst_b.definition, "второй инстанс остаётся на shared definition"
  end

  def test_mutable_collection_tolerates_entities_without_make_unique
    g = FakePlainGroup.new
    assert_equal [:g], E.mutable_entity_collection(g)
  end

  def test_readonly_entity_collection_does_not_make_unique
    shared = FakeDefinition.new([:shared_face])
    inst = FakeInstance.new(shared)
    E.entity_collection(inst)
    assert_equal 0, inst.make_unique_calls,
      "read-only обход НЕ должен плодить уникальные definitions"
  end
end
```

Run: `ruby test/test_entities_unique.rb` → RED (`mutable_entity_collection` не определён).

- [ ] **Step 2: GREEN — `helpers/entities.rb`**

После `entity_collection` добавить:

```ruby
      # T-16: definition.entities у ComponentInstance (и у copy-paste-копий
      # Group — SketchUp шарит definition группы до первого редактирования
      # или make_unique) ШАРИТСЯ между инстансами — мутация через
      # entity_collection красит/режет все копии разом («четыре стула
      # краснеют одним set_material»). Мутирующие хендлеры обязаны ходить
      # сюда: make_unique отвязывает entity в собственную definition (для
      # уже-уникального — дёшево, для объекта без make_unique — no-op).
      # Read-only обходы (list/find/get_component_info) остаются на
      # entity_collection.
      def self.mutable_entity_collection(group_or_component)
        group_or_component.make_unique if group_or_component.respond_to?(:make_unique)
        entity_collection(group_or_component)
      end
```

- [ ] **Step 3: Переключить мутирующие call-sites (три файла)**

- `handlers/materials.rb::apply_to_entity`: `E.entity_collection(entity)` → `E.mutable_entity_collection(entity)` (+ строку в комментарий над методом: `# T-16: mutable_* — покраска одного инстанса не должна красить остальные копии.`)
- `handlers/joints.rb::place_tenon`: `entities = E.entity_collection(board)` → `entities = E.mutable_entity_collection(board)`
- `handlers/joints.rb::add_parent_frame_prototype`: `E.entity_collection(board).add_instance(...)` → `E.mutable_entity_collection(board).add_instance(...)`
- `handlers/operations.rb::run_edge_op`: `target_entities = E.entity_collection(entity)` → `target_entities = E.mutable_entity_collection(entity)` (chamfer/fillet перестраивают рёбра внутри entity — мутация; строка `cur_edges = E.entity_collection(entity)` находится в ДРУГОМ методе — `find_current_edge_spec` (operations.rb) — и остаётся: она читает entity, уже сделанный уникальным в run_edge_op).

⚠ Проверить пины: `ruby test/test_joints_frame_compensation.rb` standalone — FakeBoard не имеет `make_unique`, guard `respond_to?` пропускает; source-пины этого файла текст `place_tenon`/`add_parent_frame_prototype` НЕ пинят построчно (только carve_*-роутинг и sibling-cutter). Также (P-16) прогнать `ruby test/test_operation_names.rb` standalone — он пинит текст operation-хендлеров, а `run_edge_op` меняется; по сверке ревью его пины держат лейблы операций и subtract-паттерны (замену entity_collection задеть не должны), но при падении пина обновить осознанно в этом же коммите.

- [ ] **Step 4: Прогнать + commit**

```bash
ruby test/test_entities_unique.rb            # 3 runs, 0 failures
ruby test/test_joints_frame_compensation.rb  # пины живы
ruby test/run_all.rb                         # 0 failures
uv run pytest tests/ -q                      # 168 passed (не задет)
git add mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb mcp_for_sketchup/mcp_for_sketchup/handlers/materials.rb mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb test/test_entities_unique.rb
git commit -m "fix: make instances unique before mutating shared definition entities (T-16)"
```

---

### Task 13: Валидация параметров + min-dims + case-insensitive поиск (T-17 + MR-2 + T-18)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb` (новые `optional_number`, `optional_string`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (min-dims, scale, polar chord)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` (angle, offsets ×9)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb` (типы recursive/max_depth/name/layer/type + T-18 downcase)
- Modify: `src/sketchup_mcp/tools.py` (зеркала: dims ≥ 1, scale ≠ 0, angle ≤ 60)
- Test: `test/test_geometry_builders.rb`, `test/test_joints_validation.rb` (новый), `test/test_model_pagination.rb`, `tests/test_tools.py`

**Interfaces:**
- Produces: `V.optional_number(params, key, default = 0.0)` (строгий Numeric,→ Float), `V.optional_string(params, key)` (nil-pass-through, иначе require_string); `Geometry::MIN_DIMENSION_MM_BOX = 0.1`, `Geometry::MIN_DIMENSION_MM_CURVED = 1.0`, `Geometry.validate_min_dimensions!(dims_mm, type)` (per-type floor — решение P-13+C-13), `Geometry::MIN_POLAR_CHORD_MM = 0.04`; Python: элементы `dimensions` — `Field(ge=0.1)` (абсолютный floor; точный per-type — Ruby-инстанция), `scale` — `AfterValidator(_validate_scale_nonzero)`, dovetail `angle` — `Field(gt=0, le=60)`.
- Consumes: `V.optional_bool`, `V.optional_int_positive`, `V.optional_enum` (Task 7), `dispatch_conn`.

- [ ] **Step 1: Ruby V-хелперы (`helpers/validation.rb`, после `optional_bool`)**

```ruby
      # T-17: строгий опциональный Numeric (joints-offsets шли через голый
      # .to_f — строка "abc" молча становилась 0.0).
      def self.optional_number(params, key, default = 0.0)
        return default unless params.key?(key)
        v = params[key]
        raise E.new(-32602, "field #{key} must be a number, got #{v.inspect}") unless v.is_a?(Numeric)
        v.to_f
      end

      def self.optional_string(params, key)
        return nil unless params.key?(key)
        require_string(params, key)
      end
```

- [ ] **Step 2: RED — Ruby-тесты**

2a. В `test/test_geometry_builders.rb` (в класс `TestGeometryBuilders`):

```ruby
  # ---------- MR-2: минимальные размеры (per-type — решение P-13+C-13) ----------

  def test_validate_min_dimensions_per_type_floors
    # C-13: box пропускает легитимный шпон 0.5 мм; криволинейные держат 1.0.
    assert_equal [0.5, 100.0, 100.0],
      GEO.validate_min_dimensions!([0.5, 100.0, 100.0], "cube")
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.validate_min_dimensions!([0.5, 100.0, 100.0], "cylinder")
    end
    assert_equal(-32602, err.code)
    assert_match(/dimensions\[0\]/, err.message)
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.validate_min_dimensions!([0.05, 100.0, 100.0], "cube")
    end
    assert_equal(-32602, err.code)
  end

  def test_validate_min_dimensions_accepts_floor
    assert_equal [1.0, 100.0, 100.0], GEO.validate_min_dimensions!([1.0, 100.0, 100.0], "sphere")
    assert_equal [0.1, 100.0, 100.0], GEO.validate_min_dimensions!([0.1, 100.0, 100.0], "cube")
  end

  def test_sphere_rejects_subtolerance_polar_chord_at_default_segments
    # d = 0.02" (0.508 мм): хорда полярного кольца 2r·sin²(π/16) ≈ 0.019 мм —
    # тоньше merge-tolerance, add_face молча склеит вершины.
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.build_sphere(FakeEntities.new, [0.0, 0.0, 0.0], [0.02, 0.02, 0.02], SEGMENTS)
    end
    assert_equal(-32602, err.code)
    assert_match(/segments|polar/i, err.message)
  end

  def test_sphere_rejects_high_segment_count_on_small_sphere
    # d = 10 мм (0.394"), 96 сегментов: статический floor 1 мм ПРОХОДИТ, но
    # хорда 2·5·sin²(π/96) ≈ 0.011 мм — вырождение ловится только формулой.
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.build_sphere(FakeEntities.new, [0.0, 0.0, 0.0], [0.394, 0.394, 0.394], 96)
    end
    assert_equal(-32602, err.code)
  end

  # ---------- T-17: scale ≈ 0 ----------

  def test_transform_component_rejects_zero_scale_before_touching_model
    # Валидация стоит ДО E.active_model! — пустой стаб Entities не нужен.
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.transform_component("id" => 1, "scale" => [0.0, 1.0, 1.0])
    end
    assert_equal(-32602, err.code)
    assert_match(/scale\[0\]/, err.message)
  end
```

2b. Новый файл `test/test_joints_validation.rb`:

```ruby
# test/test_joints_validation.rb
# T-17: угол dovetail без верхней границы (tan(→90°) — мусорная геометрия);
# joints-offsets коэрсились .to_f молча ("abc" → 0.0). Валидация стоит ДО
# обращения к модели — пустых стабов Entities достаточно.
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end
module MCPforSketchUp
  module Helpers
    module Entities; end
  end
  module Handlers
    module Geometry; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointsValidation < Minitest::Test
  J = MCPforSketchUp::Handlers::Joints

  def test_dovetail_angle_above_60_rejected
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "angle" => 75.0)
    end
    assert_equal(-32602, err.code)
    assert_match(/angle/, err.message)
  end

  def test_dovetail_angle_at_60_passes_validation
    # 60° — граница включительно. Явный сигнал вместо NoMethodError (M-04):
    # стаб active_model! кидает маркер — тест не станет ложно-зелёным, если
    # валидация переедет ниже по методу. Method сохраняется: под run_all
    # Entities реальный (def self. = singleton-метод), remove_method без
    # сохранения удалил бы его насовсем.
    e = MCPforSketchUp::Helpers::Entities
    orig = e.respond_to?(:active_model!) ? e.method(:active_model!) : nil
    e.define_singleton_method(:active_model!) { raise "validation passed" }
    err = assert_raises(RuntimeError) do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "angle" => 60.0)
    end
    assert_equal "validation passed", err.message
  ensure
    if orig
      e.define_singleton_method(:active_model!, orig)
    else
      e.singleton_class.send(:remove_method, :active_model!)
    end
  end

  def test_string_offset_rejected_not_silently_zeroed
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      J.create_mortise_tenon("mortise_id" => 1, "tenon_id" => 2, "offset_x" => "abc")
    end
    assert_equal(-32602, err.code)
    assert_match(/offset_x/, err.message)
  end
end
```

2c. В `test/test_model_pagination.rb` (класс `TestModelPagination`):

```ruby
  # ---------- T-17: типы параметров ----------

  def test_list_components_rejects_string_recursive
    with_model_stub do
      err = assert_raises(MCPforSketchUp::Core::StructuredError) do
        M.list_components({ "recursive" => "false" })
      end
      assert_equal(-32602, err.code)
    end
  end

  def test_list_components_rejects_string_max_depth
    with_model_stub do
      assert_raises(MCPforSketchUp::Core::StructuredError) do
        M.list_components({ "max_depth" => "3" })
      end
    end
  end

  def test_find_components_rejects_non_string_name_and_bad_type
    with_model_stub do
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.find_components({ "name" => 123 }) }
      assert_raises(MCPforSketchUp::Core::StructuredError) { M.find_components({ "type" => "polygon" }) }
    end
  end

  # ---------- T-18: case-insensitive поиск ----------

  def test_find_components_is_case_insensitive
    with_model_stub do
      @groups[0].name = "Table Leg"
      res = M.find_components({ "name" => "table" })
      assert_equal ["Table Leg"], res["components"].map { |c| c["name"] },
        "поиск «table» обязан находить «Table Leg» — иначе модель решает, " \
        "что объекта нет, и пересоздаёт геометрию (T-18)"
    end
  end
```

Run: `ruby test/test_geometry_builders.rb` (5 FAIL), `ruby test/test_joints_validation.rb` (angle-тест FAIL: NoMethodError вместо StructuredError; offset-тест FAIL), `ruby test/test_model_pagination.rb` (4 FAIL).

- [ ] **Step 3: GREEN — Ruby**

3a. `handlers/geometry.rb::create_component` — после `dims_mm = V.require_dimensions3(params, "dimensions")` вставить `validate_min_dimensions!(dims_mm, type)` (`type` к этому моменту уже прочитан require_enum'ом). Рядом с `default_segments_for` добавить:

```ruby
      # MR-2 (финальное ревью батча 1) + P-13/C-13 (ревью батча 2): floor
      # per-type. Box вырождается только у merge-tolerance SketchUp
      # (0.001" = 0.0254 мм) — floor 0.1 мм (4× запас) пропускает
      # легитимный шпон/лист 0.5–0.8 мм. Криволинейные (sphere/cylinder/
      # cone) вырождаются раньше из-за тесселяции — floor 1.0 мм; полюса
      # сфер дополнительно проверяет polar-chord формула в build_sphere.
      MIN_DIMENSION_MM_BOX    = 0.1
      MIN_DIMENSION_MM_CURVED = 1.0

      def self.validate_min_dimensions!(dims_mm, type)
        floor = type == "cube" ? MIN_DIMENSION_MM_BOX : MIN_DIMENSION_MM_CURVED
        dims_mm.each_with_index do |d, i|
          next if d >= floor
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "dimensions[#{i}] must be >= #{floor} mm for type #{type}, got #{d} — " \
            "sub-millimeter geometry collapses into SketchUp's merge tolerance")
        end
        dims_mm
      end
```

3b. `transform_component` — после `scale = V.optional_coords3(params, "scale")` (и ДО `model = E.active_model!`) вставить:

```ruby
        # T-17: |s| ≤ 1e-9 — сингулярная матрица, необратимая порча геометрии;
        # на SU2026 Transformation#inverse на ней кидает ArgumentError.
        # Fail-closed до старта operation.
        scale&.each_with_index do |s, i|
          next if s.abs > 1e-9
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "field scale[#{i}] must be non-zero (|s| > 1e-9), got #{s}")
        end
```

3c. `build_sphere` — после существующего `raise ... if segments < 3` и строки `radius = dims[0] / 2.0` вставить (константа — рядом с MIN_DIMENSION_MM):

```ruby
      MIN_POLAR_CHORD_MM = 0.04  # ~1.6 × merge-tolerance (0.0254 мм) — P-13
```

```ruby
        # MR-2: самое короткое ребро UV-сферы — хорда первого полярного
        # кольца: 2·r·sin²(π/segments). Тоньше MIN_POLAR_CHORD_MM (~1.6×
        # merge-tolerance) — add_face молча склеит вершины, оболочка выйдет
        # дырявой (floor'ом это не ловится: d=10 мм при segments=96 вырожден).
        polar_chord_mm = 2.0 * U.inch_to_mm(radius) * Math.sin(Math::PI / segments)**2
        if polar_chord_mm < MIN_POLAR_CHORD_MM
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "sphere too small for #{segments} segments: polar-ring chord " \
            "#{polar_chord_mm.round(4)} mm < #{MIN_POLAR_CHORD_MM} mm — " \
            "reduce segments or enlarge the sphere")
        end
```

3d. `handlers/joints.rb::create_dovetail` — после строки `angle = V.optional_positive(params, "angle", 15.0)`:

```ruby
        # T-17: tan(angle) при angle→90° взрывается — «ласточкины хвосты»
        # вырождаются в мусорную геометрию. Практичный предел — 60°.
        if angle > 60.0
          raise Core::StructuredError.new(-32602,
            "field angle must be in (0, 60] degrees, got #{angle}")
        end
```

3e. `handlers/joints.rb` — все девять строк offsets вида `ox = U.mm_to_inch((params["offset_x"] || 0.0).to_f)` заменить на `ox = U.mm_to_inch(V.optional_number(params, "offset_x"))` (аналогично oy/oz во всех трёх хендлерах).

3f. `handlers/model.rb`:
- `list_components`: `recursive = params.fetch("recursive", false)` → `recursive = V.optional_bool(params, "recursive", false)`; `max_depth = params.fetch("max_depth", DEFAULT_MAX_DEPTH)` → `max_depth = V.optional_int_positive(params, "max_depth", DEFAULT_MAX_DEPTH)`.
- `find_components`: заменить четыре строки чтения параметров:

```ruby
        name_substring = V.optional_string(params, "name")
        layer_name     = V.optional_string(params, "layer")
        type_filter    = V.optional_enum(params, "type", %w[group component])
        max_depth      = V.optional_int_positive(params, "max_depth", DEFAULT_MAX_DEPTH)
```

- T-18 — в `find_components` перед `results = all.select` добавить `needle = name_substring&.downcase`, и в фильтре заменить `(name_substring.nil? || c["name"].include?(name_substring))` на `(needle.nil? || c["name"].downcase.include?(needle))` (+ комментарий `# T-18: case-insensitive — «table» находит «Table Leg»`).

- [ ] **Step 4: Прогнать Ruby**

```bash
ruby test/test_geometry_builders.rb   # 0 failures
ruby test/test_joints_validation.rb   # 3 runs, 0 failures
ruby test/test_model_pagination.rb    # 0 failures
ruby test/test_joints_frame_compensation.rb  # offsets-правка не задела carve-математику
ruby test/run_all.rb                  # 0 failures
```

- [ ] **Step 5: RED+GREEN — Python-зеркала**

⚠ P-05 (решение ревью): «зеркальность» Python-констрейнтов — по ГРАНИЦАМ значений (ge/le/gt), НЕ по строгости типов. Коэрция pydantic ("3"→3, "false"→False) оставлена намеренно: Python-схемы обслуживают LLM (числа строками — норма), строгая инстанция типов — Ruby-валидация, которая ловит direct-TCP клиентов. Единственное типовое исключение — bool в EntityId (закрыт strict-веткой в Task 5).

5a. RED-тесты в `tests/test_tools.py`:

```python
# --- T-17 + MR-2: зеркальные констрейнты схем ---

async def test_schema_rejects_below_absolute_floor(dispatch_conn):
    """Python держит АБСОЛЮТНЫЙ floor 0.1 мм; per-type floor (1.0 для
    криволинейных) — Ruby-инстанция: кросс-полевая (type+dimensions)
    валидация на pydantic-стороне неоправданно сложна (P-05/P-13)."""
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [0.05, 100.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_zero_scale_component(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("transform_component", {"id": "5", "scale": [0.0, 1.0, 1.0]})
    assert "scale" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_dovetail_angle_above_60(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_dovetail",
                            {"tail_id": "1", "pin_id": "2", "angle": 75.0})
    assert "angle" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()
```

Run → 3 FAIL (валидация отсутствует).

5b. GREEN — `tools.py`:
- импорт: `from pydantic import AfterValidator, Field`;
- module-level (после `EntityId = ...`):

```python
def _validate_scale_nonzero(v: list[float]) -> list[float]:
    # T-17 (зеркало Ruby): |s| <= 1e-9 — сингулярная матрица; SU2026
    # Transformation#inverse на ней кидает ArgumentError.
    for i, s in enumerate(v):
        if abs(s) <= 1e-9:
            raise ValueError(f"scale[{i}] must be non-zero (|s| > 1e-9)")
    return v
```

- `create_component`: элемент dimensions `Annotated[float, Field(gt=0)]` → `Annotated[float, Field(ge=0.1)]` (абсолютный floor box'а; per-type floor 1.0 мм для sphere/cylinder/cone проверяет Ruby; докстринг — Task 15);
- `transform_component`: параметр `scale` →

```python
    scale: Optional[
        Annotated[list[float], Field(min_length=3, max_length=3),
                  AfterValidator(_validate_scale_nonzero)]
    ] = None,
```

- `create_dovetail`: `angle: Annotated[float, Field(gt=0)] = 15.0` → `angle: Annotated[float, Field(gt=0, le=60)] = 15.0`;
- `find_components`: `name`/`layer` → `Annotated[str, Field(min_length=1)] | None = None` (M-06: зеркало Ruby-цепочки `optional_string` → `require_string`, где пустая строка уже невалидна — «"" как фильтр» не пропускаем ни с одной стороны).

- [ ] **Step 6: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **171 passed** (168 + 3). ⚠ Wire-pin таблица не задета: строка create_component передаёт `[1, 1, 1]` — выше floor'а (≥ 0.1 ✓; int 1 проходит `Field(ge=0.1)` — pydantic v2 коэрсит int→float при числовом сравнении, M-05).

```bash
git add mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb src/sketchup_mcp/tools.py test/test_geometry_builders.rb test/test_joints_validation.rb test/test_model_pagination.rb tests/test_tools.py
git commit -m "fix: parameter validation batch — min dims, zero scale, dovetail angle, strict types, case-insensitive find (T-17, MR-2, T-18)"
```

---

### Task 14: Ruby-тестовые пробелы + rotated-board coverage (T-23 + MR-3)

**Files:**
- Test: `test/test_server_multi_client.rb` (FIFO-spy, read-cap)
- Test: `test/test_dispatch_post_handshake.rb` (error-paths dispatch)
- Test: `test/test_pure_helpers.rb` (новый: pick_color, filter_edges, closest_face)
- Test: `test/test_joints_frame_compensation.rb` (MR-3: rotated-board класс)

Только тесты — производственный код НЕ меняется. Если какой-то тест обнаружит реальный баг — СТОП, зафиксировать в ledger и обсудить (не чинить молча).

**Interfaces:**
- Consumes: `Handlers::Dispatch.handle` (envelope-in/envelope-out), `Server::READ_MAX_ITERATIONS`/`DISPATCH_MAX_PER_TICK` (Task 10), паттерн save-Method/define_singleton_method.

- [ ] **Step 1 (T-23.1): FIFO-интерливинг между клиентами через spy на Dispatch.handle**

В `test/test_server_multi_client.rb`:

```ruby
  # ---------- T-23.1: глобальный FIFO — прямой spy на Dispatch.handle ----------

  def test_global_dispatch_order_is_decode_arrival_fifo
    # Существующие FIFO-тесты смотрят на per-socket ответы — интерливинг
    # МЕЖДУ клиентами они не поймают. Spy пишет глобальную последовательность
    # request-id: клиент A дренируется целиком раньше B (accept-order), внутри
    # клиента — decode-order. Ожидание: [1, 2, 101, 102].
    dispatch_mod = MCPforSketchUp::Handlers::Dispatch
    original = dispatch_mod.method(:handle)
    seen_ids = []
    dispatch_mod.define_singleton_method(:handle) do |request|
      seen_ids << request["id"] if request.is_a?(Hash) && request["method"] == "tools/call"
      original.call(request)
    end
    begin
      a = FakeSocket.new(read_chunks: [hello_frame + gv_frame(1) + gv_frame(2)])
      b = FakeSocket.new(read_chunks: [hello_frame + gv_frame(101) + gv_frame(102)])
      fs = FakeServer.new([a, b])
      run_one_tick(fs)
      assert_equal [1, 2, 101, 102], seen_ids,
        "FIFO по (accept-order, decode-order) нарушен"
    ensure
      dispatch_mod.define_singleton_method(:handle, original)
    end
  end
```

- [ ] **Step 2 (T-23.2): кап 50 reads/tick**

```ruby
  # ---------- T-23.2: READ_MAX_ITERATIONS ----------

  class CountingSocket < FakeSocket
    attr_reader :reads
    def initialize(*args, **kwargs)
      super
      @reads = 0
    end
    def read_nonblock(n)
      @reads += 1
      super
    end
  end

  def test_reads_per_client_capped_per_tick
    cap = MCPforSketchUp::Core::Server::READ_MAX_ITERATIONS
    # cap+5 чанков по одному мелкому фрейму: за тик — ровно cap чтений,
    # остаток дочитывается следующим тиком (кап держит UI отзывчивым).
    chunks = [hello_frame] + (1..(cap + 4)).map { |i| gv_frame(i) }
    sock = CountingSocket.new(read_chunks: chunks)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    assert_equal cap, sock.reads,
      "за тик допустимо ровно READ_MAX_ITERATIONS чтений"
    srv.send(:on_timer_tick)
    assert_operator sock.reads, :>, cap, "следующий тик дочитывает остаток"
  end
```

⚠ Хвостовые фреймы диспатчатся под капом DISPATCH_MAX_PER_TICK (Task 10) за 2 тика — ассерты выше сознательно смотрят только на КОЛИЧЕСТВО ЧТЕНИЙ, не на ответы.

Прогнать оба: `ruby test/test_server_multi_client.rb` → 0 failures (это gap-filling тесты: они обязаны пройти на СУЩЕСТВУЮЩЕМ коде; если упали — найден баг, СТОП по правилу задачи).

```bash
git add test/test_server_multi_client.rb
git commit -m "test: pin cross-client FIFO dispatch order and per-tick read cap (T-23)"
```

- [ ] **Step 3 (T-23.3): error-paths dispatch**

⚠ C-11 (ревью): ScriptError-arm УЖЕ покрыт существующим зелёным тестом `test_dispatch_returns_error_envelope_for_script_error_from_any_handler` (test_dispatch_post_handshake.rb:~243) — дубликат не добавляем. Реальную дыру закрывает только StandardError-тест. Это gap-filling: обязан PASS на существующем коде.

В `test/test_dispatch_post_handshake.rb` добавить (класс и require-структура уже в файле; паттерн подмены хендлера — save-Method/define_singleton_method, как в шаге 1):

```ruby
  # ---------- T-23.3: error-path dispatch (StandardError) ----------
  # ScriptError-arm уже запинен test_dispatch_returns_error_envelope_for_
  # script_error_from_any_handler — здесь только непокрытый StandardError.

  def test_handler_standard_error_becomes_minus_32603_with_id
    sys = MCPforSketchUp::Handlers::System
    original = sys.method(:get_version)
    sys.define_singleton_method(:get_version) { |_params| raise "handler exploded" }
    begin
      resp = MCPforSketchUp::Handlers::Dispatch.handle(
        "jsonrpc" => "2.0", "method" => "tools/call",
        "params" => { "name" => "get_version", "arguments" => {} }, "id" => 7)
      assert_equal(-32603, resp["error"]["code"])
      assert_includes resp["error"]["message"], "handler exploded"
      assert_equal 7, resp["id"], "id обязан пережить error-path (matching на клиенте)"
    ensure
      sys.define_singleton_method(:get_version, original)
    end
  end
```

Run: `ruby test/test_dispatch_post_handshake.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add test/test_dispatch_post_handshake.rb
git commit -m "test: cover dispatch StandardError error path (T-23)"
```

- [ ] **Step 4 (T-23.4): чистые хелперы — новый файл `test/test_pure_helpers.rb`**

```ruby
# test/test_pure_helpers.rb
# T-23: тривиально тестируемые без SketchUp чистые хелперы не были покрыты
# вовсе: pick_color (materials), filter_edges (operations), closest_face
# (joints).
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end
module Sketchup
  # Guarded: реальный API даёт Sketchup::Color; в юнит-среде достаточно
  # RGB-контейнера.
  unless const_defined?(:Color)
    class Color
      attr_reader :rgb
      def initialize(*rgb)
        @rgb = rgb
      end
    end
  end
  unless const_defined?(:Face)
    class Face; end
  end
  unless const_defined?(:Edge)
    class Edge; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/materials"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestPureHelpers < Minitest::Test
  MAT = MCPforSketchUp::Handlers::Materials
  OPS = MCPforSketchUp::Handlers::Operations
  J   = MCPforSketchUp::Handlers::Joints

  # ---------- pick_color ----------

  def test_pick_color_named_case_insensitive
    assert_equal [184, 134, 72], MAT.pick_color("Wood").rgb
    assert_equal [255, 0, 0],    MAT.pick_color("red").rgb
  end

  def test_pick_color_hex
    assert_equal [160, 80, 48], MAT.pick_color("#a05030").rgb
  end

  def test_pick_color_invalid_raises_32602
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { MAT.pick_color("#XYZ") }
    assert_equal(-32602, err.code)
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { MAT.pick_color("mahogany") }
    assert_equal(-32602, err.code)
  end

  # ---------- filter_edges ----------

  def test_filter_edges_selects_by_positional_index
    edges = %w[e0 e1 e2 e3]
    assert_equal %w[e1 e3], OPS.filter_edges(edges, [1, 3])
    assert_equal [],        OPS.filter_edges(edges, [])
    assert_equal %w[e0],    OPS.filter_edges(edges, [0, 99])  # несуществующий индекс молча пропущен
  end

  # ---------- closest_face ----------

  FakeVec = Struct.new(:x, :y, :z) do
    def clone
      FakeVec.new(x, y, z)
    end
    def normalize!
      self  # closest_face сравнивает |компоненты| — нормализация не влияет
    end
  end

  def test_closest_face_picks_dominant_axis
    assert_equal :east,   J.closest_face(FakeVec.new(5.0, 1.0, 1.0))
    assert_equal :west,   J.closest_face(FakeVec.new(-5.0, 1.0, 1.0))
    assert_equal :north,  J.closest_face(FakeVec.new(1.0, 5.0, 1.0))
    assert_equal :south,  J.closest_face(FakeVec.new(1.0, -5.0, 1.0))
    assert_equal :top,    J.closest_face(FakeVec.new(1.0, 1.0, 5.0))
    assert_equal :bottom, J.closest_face(FakeVec.new(1.0, 1.0, -5.0))
  end

  def test_closest_face_tie_prefers_x_then_y
    assert_equal :east, J.closest_face(FakeVec.new(1.0, 1.0, 1.0))
    assert_equal :north, J.closest_face(FakeVec.new(0.0, 1.0, 1.0))
  end
end
```

⚠ Если `handlers/operations.rb` при загрузке с пустыми Helpers-стабами падает (module-level зависимости), допускается протестировать `filter_edges` через `OPS.method(:filter_edges)` после require с реальными helpers — но сперва попробовать как написано (operations.rb, как и joints.rb, содержит только `V = ...`-алиасы на module-level, пустых модулей достаточно).

Run: `ruby test/test_pure_helpers.rb && ruby test/run_all.rb` → 0 failures (gap-filling: обязаны пройти).

```bash
git add test/test_pure_helpers.rb
git commit -m "test: cover pure helpers pick_color, filter_edges, closest_face (T-23)"
```

- [ ] **Step 5 (MR-3): rotated-board coverage для frame-компенсации**

В конец `test/test_joints_frame_compensation.rb` добавить НОВЫЙ класс (свои фейки; существующий translation-only класс не трогать — см. его шапку про subtract_log):

```ruby
# MR-3 (финальное ревью батча 1): translation-only алгебра не доказывает
# компенсацию T⁻¹ для ПОВЁРНУТЫХ досок. Аффинная подгруппа: повороты вокруг
# Z на 0/90/180/270 (точная целочисленная математика — без float-фазза) +
# сдвиг. Компенсация add_parent_frame_prototype (T_inst = T_board⁻¹) обязана
# сокращать И поворот: world = T_board ∘ T_board⁻¹ ∘ p = p.
# C-09: тест доказывает АЛГОРИТМ компенсации (логику T⁻¹); float-поведение
# реального Geom::Transformation при композиции матриц покрывает только
# живой smoke на SketchUp.
class TestJointsFrameCompensationRotated < Minitest::Test
  J  = MCPforSketchUp::Handlers::Joints
  EH = MCPforSketchUp::Helpers::Entities

  def self.subtract_log
    @subtract_log ||= []
  end

  FakePoint = Struct.new(:x, :y, :z)

  class FakeBounds
    attr_reader :min, :max
    def initialize(min, max)
      @min, @max = min, max
    end
    def center
      FakePoint.new((min.x + max.x) / 2.0, (min.y + max.y) / 2.0, (min.z + max.z) / 2.0)
    end
  end

  # Поворот вокруг Z на deg ∈ {0, 90, 180, 270} + сдвиг: apply = R(p) + d.
  class FakeAffineZ
    attr_reader :deg, :dx, :dy, :dz
    def initialize(deg = 0, dx = 0.0, dy = 0.0, dz = 0.0)
      @deg = deg % 360
      @dx, @dy, @dz = dx, dy, dz
    end

    def rot(x, y)
      case deg
      when 0   then [x, y]
      when 90  then [-y, x]
      when 180 then [-x, -y]
      else          [y, -x]
      end
    end

    def apply(p)
      x, y = rot(p[0], p[1])
      [x + dx, y + dy, p[2] + dz]
    end

    # self ∘ other: сначала other, потом self.
    # (A∘B).apply(p) = R_A(R_B(p) + d_B) + d_A = R_{A+B}(p) + (R_A(d_B) + d_A)
    def compose(other)
      ox, oy = rot(other.dx, other.dy)
      FakeAffineZ.new(deg + other.deg, ox + dx, oy + dy, dz + other.dz)
    end

    # T⁻¹: R⁻¹(p − d) = R_{−deg}(p) − R_{−deg}(d)
    def inverse
      inv = FakeAffineZ.new((360 - deg) % 360)
      ix, iy = inv.rot(-dx, -dy)
      FakeAffineZ.new((360 - deg) % 360, ix, iy, -dz)
    end
  end

  class FakeFace
    def pushpull(_amount); end
  end

  class FakeCollection
    attr_reader :faces, :groups, :instances
    def initialize
      @faces, @groups, @instances = [], [], []
    end
    def add_face(*pts)
      @faces << pts
      FakeFace.new
    end
    def add_group
      g = FakeGroup.new(parent_collection: self)
      @groups << g
      g
    end
    def add_instance(definition, transformation)
      @instances << { definition: definition, transformation: transformation }
      definition.owner
    end
  end

  class FakeGroup
    attr_reader :entities, :transformation
    def initialize(parent_collection: nil)
      @parent_collection = parent_collection
      @entities = FakeCollection.new
      @transformation = FakeAffineZ.new
      @valid = true
    end
    def definition
      @definition ||= Struct.new(:owner).new(self)
    end
    def transform!(t)
      # SketchUp transform!: результат = t ∘ старая (t применяется ПОСЛЕ).
      @transformation = t.compose(@transformation)
      self
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def subtract(target)
      TestJointsFrameCompensationRotated.subtract_log << [self, target]
      result = FakeGroup.new(parent_collection: @parent_collection)
      @parent_collection.groups << result if @parent_collection
      erase!
      target.erase! if target.respond_to?(:erase!)
      result
    end
  end

  class FakeBoard < Sketchup::Group
    attr_reader :entities, :bounds, :transformation
    def initialize(bounds:, transformation:)
      @entities = FakeCollection.new
      @bounds = bounds
      @transformation = transformation
    end
  end

  class FakeModel
    attr_reader :active_entities
    def initialize
      @active_entities = FakeCollection.new
    end
  end

  # Доска «создана у origin (x 0..4, y 0..4), повёрнута на 90° и сдвинута
  # на dx=30»: R90 даёт x' = −y + 30 ∈ [26..30], y' = x ∈ [0..4] — мировой
  # bbox (родительский фрейм) x 26..30, y 0..4 (C-14: легенда согласована
  # с трансформацией алгебраически).
  def make_rotated_board
    FakeBoard.new(
      bounds: FakeBounds.new(FakePoint.new(26.0, 0.0, 0.0), FakePoint.new(30.0, 4.0, 1.0)),
      transformation: FakeAffineZ.new(90, 30.0, 0.0, 0.0),
    )
  end

  def setup
    self.class.subtract_log.clear
    @model = FakeModel.new
    model = @model
    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
  end

  # Мировые (x, y) всех точек, достижимых из коллекции доски: аккумулируем
  # композицию трансформаций сверху вниз.
  def world_points(board)
    pts = []
    walk = lambda do |coll, acc|
      coll.faces.each { |face| face.each { |p| pts << acc.apply(p) } }
      coll.groups.each { |g| walk.call(g.entities, acc.compose(g.transformation)) }
      coll.instances.each do |inst|
        walk.call(inst[:definition].owner.entities, acc.compose(inst[:transformation]))
      end
    end
    walk.call(board.entities, board.transformation)
    pts
  end

  DEPTH = 0.5

  def assert_geometry_on_board(board, label)
    pts = world_points(board)
    refute_empty pts, "#{label} must add geometry into the board"
    lo_x = board.bounds.min.x - DEPTH - 1e-6
    hi_x = board.bounds.max.x + DEPTH + 1e-6
    lo_y = board.bounds.min.y - DEPTH - 1e-6
    hi_y = board.bounds.max.y + DEPTH + 1e-6
    xs = pts.map { |p| p[0] }
    ys = pts.map { |p| p[1] }
    assert xs.min >= lo_x && xs.max <= hi_x && ys.min >= lo_y && ys.max <= hi_y,
      "#{label}: геометрия ушла с ПОВЁРНУТОЙ доски (x #{xs.min.round(3)}..#{xs.max.round(3)}, " \
      "y #{ys.min.round(3)}..#{ys.max.round(3)}; допустимо x #{lo_x}..#{hi_x}, y #{lo_y}..#{hi_y}) — " \
      "компенсация T_board⁻¹ не сокращает поворот (MR-3)"
  end

  def test_carve_tails_lands_on_rotated_board
    board = make_rotated_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_tails")
  end

  def test_carve_board1_fingers_lands_on_rotated_board
    board = make_rotated_board
    J.reset_joint_stats!
    J.carve_board1_fingers(board, 2.0, 2.0, DEPTH, 5, 0, 0, 0)
    assert_geometry_on_board(board, "carve_board1_fingers")
  end
end
```

Проверка дискриминативности (обязательна): в `world_points` временно заменить `acc.compose(inst[:transformation])` на `acc` — это эквивалент пропуска компенсации T_inst (`acc ≡ acc.compose(identity)`; сам `acc` уже содержит T_board, поэтому мировые точки прототипа получат ЛИШНИЙ поворот+сдвиг и уйдут с доски) — оба теста обязаны УПАСТЬ; вернуть обратно. Если в этой конфигурации какой-то из них НЕ упал — СТОП: значит фейки не воспроизводят компенсирующую механику, разбираться, не подгонять (C-14).

Run: `ruby test/test_joints_frame_compensation.rb && ruby test/run_all.rb` → 0 failures.

```bash
git add test/test_joints_frame_compensation.rb
git commit -m "test: prove joint frame compensation cancels rotation, not just translation (MR-3)"
```

### Task 15: Докстринг-оверхол всех 22 тулов + синк prompts.py (T-05)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (все регистрации)
- Modify: `src/sketchup_mcp/prompts.py` (§1, §4)
- Test: `tests/test_tool_descriptions.py` (новый), `tests/test_prompts.py` (пины могут потребовать осознанного обновления)

**Interfaces:**
- Consumes: финальные сигнатуры Task 5–9, 13 (EntityId, name, пагинация, метаданные скриншота, констрейнты).
- Produces: только описания — ни одной смены поведения/wire. Каждый параметр каждого тула получает `Field(description=...)`; каждый докстринг — units и строку «Returns:».

**Формы ответов (сверено с хендлерами — для строк «Returns:»):**

| Тул | Returns (JSON) |
|---|---|
| create_component, transform_component, set_material, boolean_operation | `{id, name, type, bbox_mm{min,max} \| null}` |
| chamfer_edge | то же + `edges_chamfered`, `stats{attempted, failed}` |
| fillet_edge | то же + `edges_filleted`, `stats{attempted, failed}` |
| create_mortise_tenon | `{mortise: {...}, tenon: {...}, boolean_cuts{attempted, failed}}` |
| create_dovetail | `{tail: {...}, pin: {...}, boolean_cuts{attempted, failed}}` |
| create_finger_joint | `{board1: {...}, board2: {...}, boolean_cuts{attempted, failed}}` |
| delete_component, undo | `{ok: true}` |
| export_scene | `{path, format[, warning]}` |
| get_model_info | `{path, title, units:"mm", bounding_box_mm \| null, entity_count, layers[]}` |
| list_components, find_components | `{components[], total, offset, truncated}` |
| get_component_info | `{id, name, type, layer, depth, bbox_mm \| null}` |
| list_layers | `{layers: [{name, visible, color, id}]}` |
| create_layer | `{id, name, visible}` |
| get_selection | `{entities: [...]}` |
| get_version | JSON-вердикт совместимости (докстринг уже полон — не трогать содержательно) |
| eval_ruby | строка: `.to_s` последнего выражения |
| get_viewport_screenshot | `[Image PNG, JSON {width, height, preset_used, style_used}]` |

- [ ] **Step 0 (P-12): инвентаризация маинтейнерских заметок**

Run: `grep -n "Ruby tool name\|Pydantic\|pydantic\|NOTE:\|Note:\|Note on" src/sketchup_mcp/tools.py`

Найдено на момент правки плана (сверить свежим grep'ом перед исполнением) — все ПЯТЬ переносятся в `#`-комментарии над функциями (правило 4 ниже):
- `:174` — `"""Export the current scene. Note: Ruby tool name is 'export'."""`
- `:193` — `...Pydantic always sends these...` (create_mortise_tenon)
- `:326-327` — `...Ruby tool name is ``chamfer_edges`` (plural); Python parameter ``id`` maps to Ruby ``entity_id``.`
- `:341-342` — `Note: Ruby tool name is ``fillet_edges`` (plural); ...maps to Ruby parameter ``entity_id``.`
- `:377` — `Note on operation order (Ruby handler): snapshot → preset → style → ...` (get_viewport_screenshot)

- [ ] **Step 1: RED — новый файл `tests/test_tool_descriptions.py`**

```python
"""T-05: контракт с LLM — докстринг и Field(description) это ЕДИНСТВЕННОЕ,
что видит модель. Тесты держат 100%-покрытие описаний и отсутствие утечек
внутренних заметок."""
import json

from sketchup_mcp.app import mcp
import sketchup_mcp.tools  # noqa: F401 — регистрация тулов


async def test_every_tool_parameter_has_description():
    tools = await mcp.list_tools()
    assert len(tools) == 22
    missing = []
    for tool in tools:
        for pname, pschema in tool.inputSchema.get("properties", {}).items():
            if not pschema.get("description"):
                missing.append(f"{tool.name}.{pname}")
    assert not missing, f"параметры без Field(description=...): {missing}"


async def test_no_internal_notes_leak_into_llm_visible_text():
    tools = await mcp.list_tools()
    for tool in tools:
        text = (tool.description or "") + json.dumps(tool.inputSchema)
        assert "Ruby tool name" not in text, f"{tool.name}: маинтейнерская заметка утекла"
        assert "pydantic" not in text.lower(), f"{tool.name}: внутренняя заметка утекла"


async def test_dimension_tools_mention_units():
    # P-08: export_scene ИСКЛЮЧЁН — у него нет линейных мм-параметров
    # (разрешение рендера в пикселях), units-требование к нему неверно.
    tools = {t.name: t for t in await mcp.list_tools()}
    for name in ("create_component", "transform_component", "chamfer_edge",
                 "fillet_edge", "create_mortise_tenon", "create_dovetail",
                 "create_finger_joint"):
        desc = tools[name].description or ""
        assert ("mm" in desc) or ("millimeter" in desc.lower()), f"{name}: нет units"


async def test_returns_lines_pin_top_response_shapes():
    """C-05: units/описания — это форма; Returns-строки топ-5 тулов пинятся
    СОДЕРЖАТЕЛЬНО, чтобы неверная форма ответа в докстринге не прошла тесты."""
    tools = {t.name: t for t in await mcp.list_tools()}
    expected_fragments = {
        "create_component": "{id, name, type, bbox_mm{min,max}|null}",
        "set_material": "{id, name, type, bbox_mm{min,max}|null}",
        "boolean_operation": "bbox_mm",
        "create_mortise_tenon": "boolean_cuts",
        "list_components": "truncated",
    }
    for name, frag in expected_fragments.items():
        desc = tools[name].description or ""
        assert frag in desc, f"{name}: Returns-пин «{frag}» не найден в докстринге"


async def test_set_material_lists_named_colors():
    tools = {t.name: t for t in await mcp.list_tools()}
    desc = tools["set_material"].description or ""
    for color in ("red", "wood", "gray", "#rrggbb"):
        assert color in desc, f"set_material: не перечислен {color}"
```

Run: `uv run pytest tests/test_tool_descriptions.py -q` → 5 FAIL (описаний нет; заметки «Ruby tool name» / «Pydantic» на месте; цвета не перечислены; Returns-пинов нет).

- [ ] **Step 2: GREEN — tools.py, общие правила**

Единые правила для ВСЕХ 22 тулов (применить к каждому):
1. У каждого параметра — `Annotated[..., Field(..., description="...")]`. Для id-параметров единый текст: `"Entity ID from a previous response (integer or its string form)"`.
2. Каждый докстринг с линейными величинами говорит «millimeters (mm)»; углы — «degrees».
3. Последняя строка докстринга — «Returns: …» из таблицы выше (+ у мутирующих: «Read bbox_mm to verify the result; it is null for empty geometry»).
4. Маинтейнерские заметки («Note: Ruby tool name is 'export'», «Pydantic always sends…», «Ruby parameter ``id`` maps to…») ПЕРЕНОСЯТСЯ из докстрингов в `#`-комментарии над функцией — они нужны разработчику, не модели.
5. НЕ менять: имена/типы/дефолты параметров, wire-пробросы (пины Task 4–13 обязаны остаться зелёными).
6. ⚠ M-11: новые тексты докстрингов и `Field(description=...)` НЕ должны содержать подстроки «Ruby tool name» и «pydantic» (в любом регистре) — их ищет leak-тест; случайное употребление уронит его.

Точные тексты ключевых докстрингов:

- `create_component`:

```python
    """Create a primitive (cube / cylinder / cone / sphere) in SketchUp.

    All linear values are millimeters (mm). Minimum size per dimension:
    0.1 mm for cube (thin stock like veneer is fine), 1.0 mm for sphere /
    cylinder / cone (tessellated types degenerate earlier). position is the
    bounding-box MIN corner (not the center); the same anchor is used by
    transform_component.position. Per-type dimensions: cube uses [x, y, z];
    cylinder and cone use [0]=diameter, [2]=height ([1] is ignored); sphere
    uses [0]=diameter only. New geometry is wrapped in a SketchUp Group.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}. Read bbox_mm to
    verify the result before the next step.
    """
```

- `transform_component` — существующий докстринг уже описывает семантику; добавить строку Returns из таблицы и `Field(description=...)` на id/position/rotation/scale (тексты: position — «ABSOLUTE target for the bbox-min corner, mm»; rotation — «relative degrees around bbox center, applied X then Y then Z»; scale — «relative factors about bbox center, each |s| > 1e-9»). C-08: добавить в докстринг фразу, что эти проверки действуют только на типизированном туле — прямой Ruby через eval_ruby их минует (escape hatch).
- `set_material`:

```python
    """Assign a material (color) to a group or component.

    material accepts a named color — red, green, blue, yellow, cyan,
    turquoise, magenta, purple, white, black, brown, wood, orange, gray,
    grey — or a 6-digit hex string like "#a05030" (#rrggbb). Anything else
    fails with error -32602. Named colors are case-insensitive. Painting
    affects only this instance (it is made unique first).

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}.
    """
```

- `export_scene` (заметку про Ruby-имя — в `#`-комментарий):

```python
    """Export the current scene to a temp file on the SketchUp host.

    Formats: skp (native), obj / dae / stl (geometry), png / jpg (viewport
    render, default 1920×1080). The file is written on the machine running
    SketchUp — on a split-host setup the path is not directly readable here.

    Returns: JSON {path, format} plus a "warning" field when exporting skp
    from a never-saved model (SketchUp binds the live document to the export
    path — relay the warning to the user).
    """
```

- `eval_ruby` — дополнить существующий докстринг абзацем:

```python
    Returns the .to_s of the LAST evaluated expression; stdout (puts) is NOT
    captured. End scripts with an explicit expression — e.g. a final
    `result.to_json` — to get structured data back. Errors return
    "[code] message" with the Ruby exception class and message.
```

- `chamfer_edge` / `fillet_edge` — докстринги без Ruby-имён:

```python
    """Chamfer (bevel) edges of a group/component by ``distance`` mm.

    By default ALL edges are chamfered. Unreliable on non-manifold geometry.

    Returns: JSON {id, name, type, bbox_mm|null, edges_chamfered,
    stats{attempted, failed}} — check stats.failed == 0.
    """
```

(fillet аналогично: «Round (fillet) edges … by ``radius`` mm with ``segments`` arc segments … edges_filleted …».)

- `create_mortise_tenon` / `create_dovetail` / `create_finger_joint` — единый шаблон:

```python
    """Create a mortise-and-tenon joint between two boards.

    All dimensions in millimeters; offsets shift the joint from the board
    face's center. Defaults are sized for ~100 mm boards. The two boards must
    already touch/overlap along the joint axis.

    Returns: JSON {mortise: {id, name, type, bbox_mm|null}, tenon: {...},
    boolean_cuts: {attempted, failed}} — non-zero failed means some cuts did
    not apply (likely non-manifold geometry); verify via bbox_mm.
    """
```

(dovetail: `{tail, pin, boolean_cuts}`, упомянуть `angle` — degrees, (0, 60]; finger: `{board1, board2, boolean_cuts}`.)

- `list_components` / `find_components` — Returns-строка `{components[], total, offset, truncated}` + «if truncated, request the next page with offset += limit»; `find_components`: «name matching is case-insensitive substring».
- `get_model_info`, `get_component_info`, `list_layers`, `create_layer`, `undo`, `get_selection`, `delete_component` — короткие докстринги + Returns из таблицы; у `get_component_info`/`delete_component` id-описание как выше.
- `get_viewport_screenshot` — параметрам добавить description; докстринг уже переписан в Task 9. P-14: добавить фразу «if the connection drops mid-response the call is retried automatically; the viewport may briefly flicker in that rare case» (тул остаётся в retry-whitelist: restore камеры отрабатывает в ensure до записи ответа — повтор идемпотентен).
- `boolean_operation` — Returns + «difference = target minus tool»; `delete_originals` description: «erase the two source bodies after a successful operation»; C-10: добавить фразу «operating on an instance of a shared definition consumes only that instance — the result is a new group, sibling instances are untouched».

- [ ] **Step 3: prompts.py — синк**

3a. §1: строку про `list_components` дополнить: `(paginated: check "truncated" and page with offset/limit)`.

3b. §4 — заменить первые два пункта:

```
- Geometry, material, boolean, and edge tools return
  {id, name, type, bbox_mm} (edge tools add edges_*/stats). bbox_mm is null
  when the entity ended up with no geometry (e.g. a boolean difference
  consumed the whole body) — treat null as "inspect what happened", not as
  an error. When bbox_mm is present, read it to confirm the result matches
  the intent before the next step (and to relocate the entity if its id
  becomes stale after destructive operations).
- Joinery tools return ONE OBJECT PER BOARD — {mortise, tenon} /
  {tail, pin} / {board1, board2}, each {id, name, type, bbox_mm} — plus
  boolean_cuts {attempted, failed}: treat failed > 0 as a partial failure
  and verify via bbox_mm.
- Other tools — delete_component, create_layer, undo, list/find
  queries, get_model_info, get_selection — have their own response
  shapes; see the tool docs.
```

3c. §3: добавить пункты `- create_component minimum dimension: 0.1 mm for cube, 1.0 mm for curved types; defaults are a 100 mm cube.` и (M-12) `- create_component accepts an optional name — set it so find_components can locate the part later.`

- [ ] **Step 4: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **176 passed** (171 + 5). ⚠ `tests/test_prompts.py` пинит фрагменты стратегии — если пины упали, обновить их под новый текст ОСОЗНАННО (в том же коммите). Wire-пины (`test_tool_wrapper_calls_ruby_correctly`) обязаны пройти без правок — поведение не менялось.

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/prompts.py tests/test_tool_descriptions.py tests/test_prompts.py
git commit -m "docs: overhaul LLM-visible descriptions of all 22 tools, sync strategy prompt (T-05)"
```

---

### Task 16: Зачистка документации + entry-points + release.md (T-25 + T-29)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/release.md`, `.gitignore`
- Modify: `src/sketchup_mcp/server.py` (докстринг), `pyproject.toml`, `src/sketchup_mcp/app.py`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/geometry.rb`, `mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb` (только комментарии)
- Delete: `diff.patch`, `docs/session-transfer-*.md` (untracked-мусор корня)

Только доки/комментарии/метаданные — поведенческих правок нет (кроме удаления entry-points группы, которую никто не потребляет).

- [ ] **Step 1 (T-25.1): несуществующие example-скрипты**

- `README.md:137-138`: ТОЛЬКО удалить строки про `arts_and_crafts_cabinet.py` и `simple_test.py, simple_ruby_eval.py, behavior_tester.py` (git log подтверждает: никогда не коммитились). ⚠ C-12: НИЧЕГО не вставлять взамен — корректные строки про `smoke_check.py`/`smoke_multi_client.py` УЖЕ стоят выше (README:135-136), вставка дала бы дубликат.

- `CLAUDE.md:91`: заменить строку `Other example scripts in ...` на:

```markdown
Other example scripts in `examples/`: `smoke_multi_client.py` (multi-client load check).
```

- [ ] **Step 2 (T-25.2): server.py — не «Legacy», а live entry point**

- `CLAUDE.md:135` (таблица Python side): строку `| \`server.py\` | Legacy connection helpers (kept for compat) |` заменить на `| \`server.py\` | CLI entry point (\`[project.scripts]\` → \`sketchup-mcp2\`) |`.
- В таблицу core/ CLAUDE.md добавить `client_state.rb` (строка `| core/ | \`application.rb\`, \`server.rb\`, \`client_state.rb\`, \`framing.rb\`, ... |`).
- `src/sketchup_mcp/server.py`: в докстринге `main()` заменить `\`\`sketchup-mcp\`\`` на `\`\`sketchup-mcp2\`\`` (фактическое имя из `[project.scripts]`).

- [ ] **Step 3 (T-25.3): названия пунктов меню в paste-verbatim инструкциях**

Фактические лейблы меню (main.rb:60-73): **«Start Server» / «Stop Server» / «Restart Server» / «Settings...» / «Show Log»**. Исправить:
- `README.md:48` и `README.md:194`: `Plugins → MCP Server → Start` → `Plugins → MCP Server → Start Server`.
- `docs/release.md:224`, `:258`, `:290`: та же замена (`→ Start` → `→ Start Server`); в :258 также «Repeated Start is idempotent» → «Repeated Start Server is idempotent».

- [ ] **Step 4 (T-25.4): висячие ссылки в комментариях**

- `helpers/geometry.rb` (комментарий над `make_box`): `See CLAUDE.md «make_box» note for context.` → `See docs/sketchup-ruby-cookbook.md (make_box recipe) for context.`
- `ui/settings_dialog.rb` (комментарий в eval-confirm блоке): `same quirk handled at settings_dialog.rb:100 for host/port restart` → `same quirk handled by the host/port restart prompt in this file` (без номера строки — он уехал и уедет снова).

- [ ] **Step 5 (T-25.5): .gitignore + мусор корня**

- В `.gitignore`, в секцию `# Local tooling`, добавить строку `.gemini/`.
- Удалить untracked-мусор: `rm diff.patch docs/session-transfer-*.md`. ⚠ НЕ трогать: `.venv.broken-task8/` (экшн владельца), `docs/superpowers/` (снимется перед PR), `.superpowers/`.

- [ ] **Step 6 (T-25): README stdlib-строка**

`README.md:174`: `ruby test/run_all.rb             # Ruby unit tests (minitest, stdlib only)` → `... (minitest; stdlib + rubyzip for the package test)`.

- [ ] **Step 7 (T-29): entry-points**

- `pyproject.toml`: удалить две строки группы `[project.entry-points.mcp]` (`sketchup = "sketchup_mcp.app:mcp"`) — потребитель неизвестен ни в python-sdk, ни в Claude Desktop/Code.
- `src/sketchup_mcp/app.py`: комментарий над side-effect импортами заменить на:

```python
# Side-effect imports: register tool/prompt handlers on `mcp`. Must come AFTER
# `mcp` is constructed (both modules do `from sketchup_mcp.app import mcp`).
# Without these imports a consumer of `sketchup_mcp.app.mcp` (the
# `sketchup-mcp2` CLI, `python -m sketchup_mcp`) would serve an EMPTY tool
# list — registration happens at import time.
```

- [ ] **Step 8 (T-25/T-04-наследие): release.md «Pending contract break»**

В `docs/release.md`, в конец блока «Pending contract break» (строка ~56) добавить:

```markdown
Batch 2 (branch `fix/deep-review-p2`) widens the same pending break: new tool
parameters (`name`, `limit`/`offset`/`response_format`), stricter validation
(min dimension 1 mm, dovetail angle ≤ 60°, non-zero scale), and changed
response shapes (`list/find_components` pagination envelope, `bbox_mm: null`
for empty bounds, screenshot metadata block, `export` warning field). Same
remedy: the release that ships them MUST bump both MIN floors.
```

- [ ] **Step 9: Прогнать + commit (двумя коммитами)**

```bash
uv run pytest tests/ -q     # 176 passed — pyproject-правка не ломает метаданных
ruby test/run_all.rb        # 0 failures (правки Ruby — только комментарии; но source-guard тесты прогнать обязательно)
git add README.md CLAUDE.md docs/release.md .gitignore src/sketchup_mcp/server.py mcp_for_sketchup/mcp_for_sketchup/helpers/geometry.rb mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb
git commit -m "docs: fix phantom examples, stale server.py role, menu labels, dangling refs (T-25)"
git add pyproject.toml src/sketchup_mcp/app.py
git commit -m "build: drop unconsumed [project.entry-points.mcp] group (T-29)"
```

(`diff.patch` и `docs/session-transfer-*.md` — untracked, их удаляет обычный `rm` из Step 5; в git-историю они не входили.)

⚠ Если `uv run pytest` после правки pyproject.toml потребует переустановку editable-пакета — `uv pip install -e .` и повторить прогон (метаданные должны пересобраться без смены версии).

---

### Task 17: Финальная верификация, счётчики, smoke-синк

**Files:**
- Modify: `examples/smoke_check.py` (ассерты пагинации)
- Modify: `CLAUDE.md` (счётчики тестов)

- [ ] **Step 1: smoke-синк — шаг 16**

В `examples/smoke_check.py`, шаг 16 (`list_components(max_depth=2)`), после строки `ids = [c["id"] for c in lc["components"]]` добавить:

```python
        # T-07: пагинационный конверт — total/truncated обязаны присутствовать;
        # смоук-модель (< 50 entities) не должна усекаться дефолтным limit.
        assert isinstance(lc["total"], int) and lc["total"] >= len(lc["components"])
        assert lc["truncated"] is False, f"unexpected truncation: {lc}"
```

(шаг 17 `find_components` — конверт тот же, отдельного ассерта не требуется; существующий `len(fc["components"]) >= 4` продолжает работать).

- [ ] **Step 2: Полные прогоны + фиксация фактических счётчиков**

```bash
ruby test/run_all.rb        # ориентир: ~413 runs (354 на старте + ~59 новых), 0 failures
uv run pytest tests/ -q     # ориентир: 176 passed
```

Записать ФАКТИЧЕСКИЕ числа из прогонов (не ориентиры!) в `CLAUDE.md:84-85`:
- строка 84: `— 354 runs / 939 assertions` → фактические runs/assertions;
- строка 85: `— 136 tests` → фактическое число passed.

Расхождение с ориентиром при 0 failures — НЕ ошибка (ориентиры статические); задокументировать фактические числа в ledger. Провал любого теста — СТОП, разбираться.

- [ ] **Step 3: Сверка ветки**

```bash
git log --oneline master..HEAD | head -40   # все коммиты Tasks 1-16 на месте
git status --short --untracked-files=no     # tracked-дерево чистое
grep -rn "double_sided_faces" mcp_for_sketchup/ && echo "ОСТАЛСЯ ОПЕЧАТАННЫЙ КЛЮЧ" || true
grep -n "arts_and_crafts" README.md CLAUDE.md || echo "фантомные примеры вычищены"
```

- [ ] **Step 4: Commit**

```bash
git add examples/smoke_check.py CLAUDE.md
git commit -m "docs: refresh test counters, assert pagination envelope in smoke (batch 2 final)"
```

---

## После плана (вне задач — исполнителю и владельцу)

1. **Финальное whole-branch mesh-ревью** (по образцу батча 1: `/claude-mesh:mesh-review default`) — диф двух батчей; per-task ревью уже несут основную нагрузку.
2. **Перед PR:** `git rm -r docs/superpowers/ && git commit` (ветка трекает P1-план, 2 review-спеки, дизайн и план батча 2, а также merged/iter-файлы дизайн-ревью — в PR-дифф не попадают, остаются в истории ветки). ⚠ C-02: git rm снимает ТОЛЬКО tracked; untracked prompt-файлы в `docs/superpowers/plans/` останутся в рабочем дереве — осознанно, это локальный архив владельца, в PR они не попадают. Затем единый PR `fix/deep-review-p2` → master, включающий ОБА батча. В описании PR напомнить владельцу 5 автономных решений батча 1 (см. ledger: пред-фикс `165f214`; commit message «3.10-3.13»; 136 vs «ровно 135»; deepseek принят REAL; спорный source-guard `5de1987`).
3. **Живой DoD (владелец, вручную):** пересобрать `.rbz` (`cd mcp_for_sketchup && ruby package.rb --variant=warehouse`), установить в SketchUp 2026, прогнать `uv run python examples/smoke_check.py` — 25 шагов зелёные (для шага 22 включить eval в Settings или собрать `--variant=github`). Проверяет живьём T-07/T-16/T-54/T-55/T-27. Дополнительно (C-10, руками один раз): скопировать группу (две копии шаренной definition), выполнить `boolean_operation` над одной — вторая обязана остаться нетронутой; это подтверждает границу T-16 «subtract не мутирует definition in-place».
4. **Владелец:** рестарт живого MCP-сервера (нужен и для батча 2 — код Python-сервера изменился) → затем `rm -rf .venv.broken-task8/`.
5. **При следующем релизе:** bump MIN-floor'ов ОБЯЗАТЕЛЕН — блок «Pending contract break» в `docs/release.md` дополнен батчем 2 (Task 16.8).
6. **Остаток бэклога отчёта:** P3 (T-31…T-49, T-51…T-53) + продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки — принять до сабмита в Extension Warehouse).





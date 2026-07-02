# P1 Critical Fixes (deep-research review, батч 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть критический батч находок многоагентного аудита (тикеты T-30, T-09, T-01, T-10, T-02, T-04, T-03, T-08, T-24 из `docs/deep-research-review-report.md`, ветка `docs/deep-research-review`): срочный cap зависимости mcp, CI, четыре живо-подтверждённых бага, гонка локов, guard-тесты и расширение smoke-матрицы.

**Architecture:** Проект — мост Claude ↔ SketchUp из двух компонентов: Python MCP-сервер (`src/sketchup_mcp/`, FastMCP + persistent TCP-клиент) и Ruby-расширение SketchUp (`mcp_for_sketchup/mcp_for_sketchup/`, TCP-сервер внутри SketchUp, обработчики в `handlers/*`). JSON-RPC 2.0 поверх 4-байтового length-prefix фрейминга. Все фиксы локальны, wire-протокол и handshake НЕ меняются.

**Tech Stack:** Python ≥3.10 (pytest, pytest-asyncio `asyncio_mode=auto`, pydantic/FastMCP), Ruby 3.2 (minitest, stdlib-only + rubyzip у одного существующего теста), GitHub Actions.

## Global Constraints

- **Единицы:** на границе MCP — миллиметры и градусы; внутри SketchUp — дюймы. Конвертация `MM = 25.4` (`helpers/units.rb`: `U.mm_to_inch` / `U.inch_to_mm`).
- **`Group#subtract` РЕВЕРСИРОВАН:** `A.subtract(B)` возвращает `B − A` (проверено эмпирически на SketchUp 2026; официальные доки противоречат сами себе). Чтобы получить «target − tool», зовут `tool.subtract(target)`. НИКОГДА не «исправлять» порядок аргументов — задача 4 как раз закрепляет это тестами.
- **Ruby-тесты:** все файлы `test/test_*.rb` (a) запускаются по одному (`ruby test/test_<name>.rb`) и (b) грузятся в ОДИН процесс через `ruby test/run_all.rb`. Поэтому: глобальные стабы (`module Sketchup`, `module Geom`) — только guarded (`unless defined?(...)`); общие singleton-поверхности не переопределять на уровне load, а патчить в `setup`/`teardown` с сохранением/восстановлением `Method`-объекта. Эталон паттерна: `test/test_collect_components.rb:232-236` (патчит `Helpers::Entities.active_model!`), `test/test_helpers_geometry.rb` (runtime-патч методов Geom::BoundingBox).
- **Прогоны:** Ruby — `ruby test/run_all.rb` (~1.3 с, базлайн 327 runs / 844 assertions / 0 failures); Python — `uv run pytest tests/ -q` (~2.4 с, базлайн 132 passed).
- **Версии не бампаем** (ни `pyproject.toml` version, ни Ruby `Compat::SERVER_VERSION`) — релизный флоу отдельный (`docs/release.md`). После мержа при релизе рекомендуется поднять MIN-floor'ы совместимости (семантика `position` меняется — см. задачу 6), но это решение релиз-времени, не этого плана.
- **Коммиты:** английские, conventional (`fix:`/`test:`/`ci:`/`build:`/`feat:`/`docs:`), без AI-атрибуции. Рабочая директория — корень репозитория, ветка `fix/deep-review-p1`.
- **Отчёт-первоисточник** (`docs/deep-research-review-report.md`) закоммичен в ДРУГОЙ ветке (`docs/deep-research-review`) и в рабочем дереве этой ветки ОТСУТСТВУЕТ — план самодостаточен, ссылки на тикеты (T-xx) и находки (RB-H-xx и т.п.) — только идентификаторы для трассировки.

## Карта задач → тикеты отчёта

| Задача | Тикет | Суть | Файлы-мишени |
|---|---|---|---|
| 1 | T-30 | cap `mcp<2` (v2 с breaking changes — июль 2026) | `pyproject.toml` |
| 2 | T-09 | CI: GitHub Actions, Ruby + Python matrix | `.github/workflows/test.yml`, `README.md` |
| 3 | T-01 | `eval_ruby("def broken(")` вешает клиента на 60 с | `handlers/eval.rb`, `handlers/dispatch.rb` |
| 4 | T-10 | Реверс `Group#subtract` не закреплён ни одним тестом | `test/`, `handlers/operations.rb` (комментарий) |
| 5 | T-02 | Сферы non-manifold: полюсные грани молча выбрасываются | `handlers/geometry.rb` |
| 6 | T-04 | `transform_component.position` — relative, подан как absolute → делаем ABSOLUTE | `handlers/geometry.rb`, `tools.py`, `prompts.py`, `smoke_check.py` |
| 7 | T-03 | dovetail/finger режут мимо на сдвинутых досках (смешение систем координат) | `handlers/joints.rb` |
| 8 | T-08 | Гонка двух локов: connect/disconnect затирают чужой сокет | `connection.py`, `app.py`, `tools.py` |
| 9 | T-24 | Smoke-матрица: сфера+boolean, dovetail на сдвинутой доске, eval-syntax-error | `examples/smoke_check.py`, `CLAUDE.md` |
| 10 | — | Финальная верификация, актуализация счётчиков тестов в доках | `CLAUDE.md`, `README.md` |

Порядок исполнения = порядок задач: 6 (absolute position) обязана идти ДО 9 (smoke использует новую семантику); 3, 5, 7 — до 9 (smoke-шаги проверяют эти фиксы).

---

### Task 1: Cap зависимости `mcp` ниже 2.0 (T-30)

**Files:**
- Modify: `pyproject.toml:20-22`
- Modify: `uv.lock` (регенерация командой, не руками)

**Interfaces:**
- Consumes: —
- Produces: диапазон `mcp[cli]>=1.27,<2` — защита пользователей от breaking-релиза mcp v2 (заявлен на июль 2026; уже опубликована 2.0.0a1). Фактически используемая версия в `uv.lock` — 1.27.0, floor поднимаем до неё же.

- [ ] **Step 1: Правка зависимости**

В `pyproject.toml` заменить:

```toml
dependencies = [
    "mcp[cli]>=1.3.0"
]
```

на:

```toml
dependencies = [
    # <2: mcp v2 (июль 2026) ломает импорт-поверхность mcp.server.fastmcp
    # (новый Dispatcher, только спека 2025-11-25). Floor 1.27 = фактическая
    # версия из uv.lock. Миграция на v2 — отдельный тикет после стабилизации.
    "mcp[cli]>=1.27,<2"
]
```

- [ ] **Step 2: Регенерировать lock**

Run: `uv lock`
Expected: `uv.lock` обновлён без изменения версии mcp (остаётся 1.27.x). Если сеть недоступна — остановиться и сообщить (lock обязателен для консистентности CI).

- [ ] **Step 3: Прогнать Python-сьюту**

Run: `uv run pytest tests/ -q`
Expected: `132 passed`

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "build: cap mcp dependency below 2.0 (v2 ships breaking changes in July 2026)"
```

---

### Task 2: CI — GitHub Actions (T-09)

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `README.md:1` (бейдж после заголовка)

**Interfaces:**
- Consumes: обе тестовые сьюты headless (Ruby ~1.3 с, Python ~2.4 с; проверено аудитом).
- Produces: workflow `test` с job'ами `ruby` и `python` — все последующие задачи плана коммитятся уже «под CI» (прогон произойдёт при push/PR).

- [ ] **Step 1: Создать workflow**

Файл `.github/workflows/test.yml` целиком:

```yaml
name: test

on:
  push:
    branches: [master]
  pull_request:
  workflow_dispatch:

jobs:
  ruby:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          # SketchUp 2024/2025 несут Ruby 3.2.x; для SU2026 то же семейство.
          ruby-version: '3.2'
      # test_package_default_variant.rb требует rubyzip (не stdlib);
      # Gemfile в проекте нет намеренно (см. deep-research T-20).
      - run: gem install rubyzip
      - run: ruby test/run_all.rb

  python:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        python-version: ['3.11', '3.12', '3.13']
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
        with:
          python-version: ${{ matrix.python-version }}
      - run: uv sync --extra dev
      - run: uv run pytest tests/ -q
```

- [ ] **Step 2: Бейдж в README**

В `README.md` сразу после первой строки (`# MCP Server for SketchUp`) вставить пустую строку и:

```markdown
[![test](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml/badge.svg)](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml)
```

- [ ] **Step 3: Локальная верификация обоих команд из workflow**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q`
Expected: `327 runs, 844 assertions, 0 failures, 0 errors, 0 skips` и `132 passed`. (Сам YAML проверится на первом push; синтаксис можно дополнительно проверить `ruby -ryaml -e 'YAML.load_file(".github/workflows/test.yml")'` → без исключений.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml README.md
git commit -m "ci: add GitHub Actions workflow — Ruby suite + Python 3.11-3.13 matrix"
```

---

### Task 3: `eval_ruby` с SyntaxError — мгновенная диагностика вместо 60-секундного зависания (T-01)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb:29-35`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb:49-54` (добавить rescue-arm)
- Test: `test/test_dispatch_post_handshake.rb` (дописать 4 теста + private-хелпер)

**Interfaces:**
- Consumes: `Core::StructuredError.new(code, message)` (`core/errors.rb:7`), диспатч-паттерн `Dispatch.handle(request) → envelope-hash` и существующий приём с toggle `Config.eval_enabled` (образец — `test_eval_ruby_succeeds_when_enabled` в том же файле).
- Produces: контракт «НИКАКОЕ исключение хендлера не роняет ответ»: `SyntaxError`/`ScriptError`/`SystemStackError` из eval'нутого кода → JSON-RPC `-32603` с `"#{класс}: #{сообщение}"` (диагностика парсера доходит до LLM); belt-and-braces arm в `Dispatch.handle` для любых будущих хендлеров. Механика бага: `SyntaxError < ScriptError`, а НЕ `StandardError`, поэтому пролетает мимо всех трёх `rescue StandardError` (dispatch.rb:49, server.rb:230, server.rb:86) — запрос молча теряется, Python ждёт полный таймаут.

- [ ] **Step 1: Написать падающие тесты**

В конец класса `TestDispatchPostHandshake` (перед закрывающим `end` файла `test/test_dispatch_post_handshake.rb`) добавить:

```ruby
  # --- T-01: не-StandardError исключения обязаны давать error-ответ ---
  # SyntaxError < ScriptError (НЕ StandardError) — до фикса пролетал мимо
  # всех rescue и запрос молча терялся (клиент ждал полный 60 s таймаут).

  def test_eval_ruby_syntax_error_returns_structured_error_fast
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "def broken(" } },
        id: 101,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp, "syntax error must produce an error envelope, not a dropped request"
      assert_equal 101, resp["id"]
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/SyntaxError/, resp["error"]["message"])
    end
  end

  def test_eval_ruby_runtime_error_message_includes_class
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "raise 'boom'" } },
        id: 102,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/RuntimeError: boom/, resp["error"]["message"])
    end
  end

  def test_eval_ruby_stack_overflow_returns_structured_error
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby",
                  # Самозацикленная lambda: SystemStackError без определения
                  # глобального метода (не мусорим в shared-process сьюте).
                  "arguments" => { "code" => "f = nil; f = -> { f.call }; f.call" } },
        id: 103,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/SystemStackError/, resp["error"]["message"])
    end
  end

  def test_dispatch_returns_error_envelope_for_script_error_from_any_handler
    sys = MCPforSketchUp::Handlers::System
    original = sys.method(:get_version)
    sys.define_singleton_method(:get_version) { |_params| raise ScriptError, "handler exploded" }
    begin
      req = make_request(method: "tools/call",
        params: { "name" => "get_version", "arguments" => {} }, id: 104)
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp, "ScriptError from a handler must not drop the response"
      assert_equal 104, resp["id"]
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/handler exploded/, resp["error"]["message"])
    ensure
      sys.define_singleton_method(:get_version, original)
    end
  end

  private

  def with_eval_enabled
    saved_eval = MCPforSketchUp::Core::Config.eval_enabled
    MCPforSketchUp::Core::Config.eval_enabled = true
    yield
  ensure
    MCPforSketchUp::Core::Config.eval_enabled = saved_eval
  end
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `ruby test/test_dispatch_post_handshake.rb`
Expected: 4 новых теста красные. `test_eval_ruby_syntax_error...` и `test_eval_ruby_stack_overflow...` и `..._script_error_from_any_handler` падают НЕ ассертом, а неперехваченным исключением (SyntaxError/SystemStackError/ScriptError вылетает из `Dispatch.handle` — ровно баг). `..._runtime_error_message_includes_class` падает ассертом (сейчас message = `"boom"` без префикса класса).

- [ ] **Step 3: Фикс `eval.rb`**

В `handlers/eval.rb` заменить строки 29-35 (от `code = V.require_string...` до `result.to_s`):

```ruby
        code = V.require_string(params, "code")
        binding_obj = TOPLEVEL_BINDING.dup
        result =
          begin
            eval(code, binding_obj)  # rubocop:disable Security/Eval
          rescue MCPforSketchUp::Core::StructuredError
            # Structured-ошибки из eval'нутого кода сохраняют code/message.
            raise
          rescue ScriptError, SystemStackError, StandardError => e
            # SyntaxError (< ScriptError) и SystemStackError — НЕ StandardError:
            # без этого arm'а они пролетают мимо всех rescue в dispatch/server,
            # запрос молча теряется и клиент висит полный таймаут (60 s).
            # Имя класса + сообщение парсера — достаточная диагностика, чтобы
            # LLM сам починил код со следующей попытки. Deep-research T-01.
            raise MCPforSketchUp::Core::StructuredError.new(
              -32603, "#{e.class}: #{e.message}"
            )
          end
        # Return raw string so dispatch.wrap_content puts it directly into
        # text-field without nesting (Python `_call` extracts text and Claude
        # sees a plain value rather than `{"result": "..."}`).
        result.to_s
```

- [ ] **Step 4: Belt-and-braces в `dispatch.rb`**

В `Dispatch.handle` после существующего arm'а `rescue StandardError => e ... end`-блока (строки 49-54) добавить ещё один arm (тем же уровнем):

```ruby
        rescue ScriptError, SystemStackError => e
          # Belt-and-braces: SyntaxError/LoadError/SystemStackError — не
          # StandardError; без этого arm'а исключение любого БУДУЩЕГО хендлера
          # молча роняло бы ответ (клиент ждал бы полный таймаут). eval.rb
          # оборачивает свой eval сам; этот arm страхует остальные пути.
          Core::Logger.log_error(tool || "?", e)
          return nil if is_notification
          Core::Errors.build_error_response(-32603, "#{e.class}: #{e.message}",
            Core::Errors.exception_to_data(e, tool || "?", params), request_id)
```

- [ ] **Step 5: Зелёный прогон**

Run: `ruby test/test_dispatch_post_handshake.rb`
Expected: все тесты файла PASS.

Run: `ruby test/run_all.rb`
Expected: 0 failures, 0 errors (runs/assertions выросли на 4/≥12).

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb \
        mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb \
        test/test_dispatch_post_handshake.rb
git commit -m "fix: eval_ruby SyntaxError/SystemStackError now returns -32603 with parser diagnostics instead of silently dropping the request"
```

---

### Task 4: Закрепить тестами реверс `Group#subtract` (T-10)

**Files:**
- Modify: `test/test_operation_names.rb` (source-level guard'ы)
- Create: `test/test_boolean_direction.rb` (поведенческий duck-typed тест)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb:40-46` (одна строка в комментарий)

**Interfaces:**
- Consumes: `Operations.boolean_operation(params)` — путь: `E.active_model!` → `model.start_operation` → `E.find!(id)` → `require_group_or_component!` → `duplicate_group` (= `entity.parent.entities.add_instance(entity.definition, entity.transformation)`) → `tool_copy.subtract(target_copy)` для difference → `describe_entity(result)` (нужны `entityID`, `name`, `bounds.min/max` с `.x/.y/.z`, `is_a?(Sketchup::Group)`) → `commit_operation`. Паттерн патча `Helpers::Entities.active_model!` — из `test_collect_components.rb:232-236`.
- Produces: гарантия «ручной флип порядка аргументов роняет сьюту» — два уровня: source-guard (грепает literal-вызов) + поведенческий тест (фиксирует, КТО receiver у `#subtract`). Сегодня флип на «очевидный» порядок проходит все 459 тестов — это самый опасный незакреплённый инвариант проекта.

- [ ] **Step 1: Source-guard'ы в `test_operation_names.rb`**

Перед закрывающим `end` класса `TestOperationNames` добавить:

```ruby
  # --- T-10: реверс Group#subtract — самый опасный инвариант проекта ---
  # SketchUp: A.subtract(B) == B − A (проверено эмпирически на SU2026;
  # официальные доки противоречат сами себе — описание метода говорит
  # this − arg, описание параметра обратное). Флип на «очевидный» порядок
  # сегодня прошёл бы всю сьюту — эти guard'ы делают его красным.

  def test_boolean_difference_receiver_is_tool_copy
    src = source(HANDLERS, "operations.rb")
    assert_match(/when "difference"\s+then tool_copy\.subtract\(target_copy\)/, src,
      "difference MUST stay tool_copy.subtract(target_copy): SketchUp's " \
      "Group#subtract is reversed (A.subtract(B) == B - A). Do NOT 'fix' " \
      "the order to match the official docs — they are self-contradictory.")
  end

  def test_edge_ops_subtract_receiver_is_cutter
    src = source(HANDLERS, "operations.rb")
    assert_match(/result = cutter\.subtract\(entity\)/, src,
      "run_edge_op must call cutter.subtract(entity) to get entity - cutter")
  end

  def test_joints_subtract_call_sites_keep_cutter_first
    src = source(HANDLERS, "joints.rb")
    [
      /subtract_tracked\(cutter,\s*board\)/,
      /subtract_tracked\(cutter,\s*pin_group\)/,
      /subtract_tracked\(cutter,\s*group\)/,
      /subtract_tracked\(cutter,\s*current\)/,
    ].each do |pattern|
      assert_match(pattern, src,
        "joints must keep the CUTTER as subtract_tracked's first arg " \
        "(receiver of the reversed Group#subtract): missing #{pattern.inspect}")
    end
  end
```

- [ ] **Step 2: Прогнать — guard'ы зелёные на текущем коде**

Run: `ruby test/test_operation_names.rb`
Expected: PASS (это регрессионные пины: они фиксируют существующее корректное поведение).

- [ ] **Step 3: Поведенческий тест — создать `test/test_boolean_direction.rb`**

Полное содержимое файла:

```ruby
# test/test_boolean_direction.rb
#
# Поведенческий пин реверса Group#subtract через Operations.boolean_operation:
# duck-typed группы записывают (receiver, argument) реального вызова #subtract.
# Source-guard'ы в test_operation_names.rb ловят правку literal-строки; этот
# файл ловит эквивалентный по тексту, но неверный по сути рефакторинг.
# Стабы — по конвенции сьюты: guarded-глобалы + setup/teardown-патч
# Helpers::Entities.active_model! (паттерн test_collect_components.rb).
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestBooleanDirection < Minitest::Test
  OPS = MCPforSketchUp::Handlers::Operations
  EH  = MCPforSketchUp::Helpers::Entities

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

  class FakeDefinition
    attr_reader :label, :bounds
    def initialize(label, bounds)
      @label, @bounds = label, bounds
    end
  end

  # add_instance = duplicate_group: возвращает «копию» с меткой copy_of_<src>.
  class FakeParentEntities
    def initialize(log)
      @log = log
    end
    def add_instance(definition, _transformation)
      FakeSolid.new(@log, label: "copy_of_#{definition.label}", bounds: definition.bounds)
    end
  end

  class FakeSolid < Sketchup::Group
    attr_reader :label, :bounds
    attr_accessor :parent
    def initialize(log, label:, bounds:)
      @log, @label, @bounds = log, label, bounds
      @valid = true
    end
    def definition
      FakeDefinition.new(@label, @bounds)
    end
    def transformation
      :identity
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def entityID
      object_id
    end
    def name
      @label
    end
    def union(other)
      @log << [:union, self, other]
      spawn_result
    end
    def subtract(other)
      @log << [:subtract, self, other]
      spawn_result
    end
    def intersect(other)
      @log << [:intersect, self, other]
      spawn_result
    end

    private

    def spawn_result
      FakeSolid.new(@log, label: "result", bounds: @bounds)
    end
  end

  class FakeModel
    def initialize(by_id)
      @by_id = by_id
    end
    def start_operation(_name, _disable_ui = true)
      true
    end
    def commit_operation
      true
    end
    def abort_operation
      true
    end
    def find_entity_by_id(int_id)
      @by_id[int_id]
    end
  end

  def setup
    @log = []
    bounds = FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(1, 2, 3))
    parent = Struct.new(:entities).new(FakeParentEntities.new(@log))
    @target = FakeSolid.new(@log, label: "target", bounds: bounds)
    @tool   = FakeSolid.new(@log, label: "tool",   bounds: bounds)
    @target.parent = parent
    @tool.parent   = parent
    model = FakeModel.new(101 => @target, 202 => @tool)
    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
  end

  def run_op(operation)
    OPS.boolean_operation(
      "operation" => operation, "target_id" => 101, "tool_id" => 202)
  end

  def test_difference_receiver_is_tool_copy_argument_is_target_copy
    run_op("difference")
    call = @log.find { |entry| entry[0] == :subtract }
    refute_nil call, "difference must go through Group#subtract"
    _, receiver, argument = call
    assert_equal "copy_of_tool", receiver.label,
      "receiver MUST be the TOOL copy: A.subtract(B) == B - A on SketchUp"
    assert_equal "copy_of_target", argument.label,
      "argument MUST be the TARGET copy"
  end

  def test_union_and_intersection_receiver_is_target_copy
    run_op("union")
    union_call = @log.find { |entry| entry[0] == :union }
    refute_nil union_call
    assert_equal "copy_of_target", union_call[1].label

    @log.clear
    run_op("intersection")
    intersect_call = @log.find { |entry| entry[0] == :intersect }
    refute_nil intersect_call
    assert_equal "copy_of_target", intersect_call[1].label
  end

  def test_originals_survive_when_delete_originals_false
    run_op("difference")
    assert @target.valid?, "original target must survive (delete_originals=false)"
    assert @tool.valid?,   "original tool must survive (delete_originals=false)"
  end
end
```

- [ ] **Step 4: Прогнать новый файл и всю сьюту**

Run: `ruby test/test_boolean_direction.rb && ruby test/run_all.rb`
Expected: PASS / 0 failures.

- [ ] **Step 5: Верифицировать, что guard реально guard'ит (адверсариальная проверка)**

Временно флипнуть `operations.rb:49` на `target_copy.subtract(tool_copy)`, запустить `ruby test/test_boolean_direction.rb test/test_operation_names.rb 2>&1 | tail -5` — ОБА файла обязаны упасть. Вернуть строку назад (`git checkout -- mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb`), перепрогнать — зелено.

- [ ] **Step 6: Постоянная ссылка в комментарии operations.rb**

В блочный комментарий `operations.rb:40-46` (перед `result = case operation`) добавить последней строкой:

```ruby
          # NB2: официальная документация Group#subtract противоречит сама себе
          # (описание метода: this−arg; описание параметра: обратное) — не
          # «чинить» под доки. Направление закреплено тестами:
          # test_boolean_direction.rb + test_operation_names.rb (T-10).
```

- [ ] **Step 7: Commit**

```bash
git add test/test_boolean_direction.rb test/test_operation_names.rb \
        mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb
git commit -m "test: pin reversed Group#subtract direction (source guards + behavioral duck-typed test)"
```

---

### Task 5: Сферы manifold — треугольники на полюсах вместо молча выброшенных граней (T-02)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb:168-181` (`build_sphere`, цикл граней)
- Create: `test/test_geometry_builders.rb`

**Interfaces:**
- Consumes: `Geometry.build_sphere(entities, pos, dims, segments)` — приватный билдер, вызываемый напрямую (module self-method); коллекция должна отвечать на `add_group`, группа — на `entities.add_face(*points)` (точки — обычные массивы `[x,y,z]` в дюймах).
- Produces: сфера — замкнутая (manifold) сетка: `segments²` граней = `segments×(segments-2)` квадов + `2×segments` полюсных ТРЕУГОЛЬНИКОВ; каждое ребро разделяют ровно 2 грани. Механика бага: в полярных рядах квад вырожден (две точки совпадают), `add_face` кидает, `rescue` логирует «skipped degenerate face at pole» и выбрасывает грань БЕЗ замены треугольником → 2×segments дыр, `manifold=false`, все booleans над сферой умирают с `-32603 likely non-manifold` (подтверждено живьём: bbox сферы d=100 по Z был `0.96…99.04` — полюса срезаны).

- [ ] **Step 1: Написать падающий тест — создать `test/test_geometry_builders.rb`**

Полное содержимое файла:

```ruby
# test/test_geometry_builders.rb
#
# Юнит-пин build_sphere без SketchUp (T-02): фейковая Entities-коллекция
# ведёт себя как SketchUp — add_face кидает на вырожденной грани (две точки
# ближе 1e-3 дюйма). До фикса полюсные квады выбрасывались rescue-глушилкой
# и сетка оставалась открытой; фикс обязан давать полный manifold-грид
# с треугольниками на полюсных полосах.
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"

class TestGeometryBuilders < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry

  # SketchUp сливает/отвергает точки ближе ~1e-3 дюйма.
  TOLERANCE = 1.0e-3
  SEGMENTS  = 16

  class FaceCollector
    attr_reader :faces
    def initialize
      @faces = []
    end
    def add_face(*pts)
      pts.combination(2) do |a, b|
        d = Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)
        raise ArgumentError, "degenerate face: duplicate points" if d < TOLERANCE
      end
      @faces << pts
      :face
    end
  end

  class FakeGroup
    attr_reader :entities
    def initialize
      @entities = FaceCollector.new
    end
  end

  class FakeEntities
    attr_reader :group
    def add_group
      @group = FakeGroup.new
    end
  end

  def setup
    # Глушим DEBUG-строку rescue-ветки build_sphere в shared-console.
    @saved_level = MCPforSketchUp::Core::Config.log_level
    MCPforSketchUp::Core::Config.log_level = "ERROR"
  end

  def teardown
    MCPforSketchUp::Core::Config.log_level = @saved_level
  end

  # Сфера диаметром 4" в начале координат: центр (2,2,2), z ∈ [0, 4].
  def build_faces
    entities = FakeEntities.new
    GEO.build_sphere(entities, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], SEGMENTS)
    entities.group.entities.faces
  end

  def rounded(pt)
    pt.map { |v| v.round(6) }
  end

  def test_sphere_emits_full_face_grid_with_pole_triangles
    faces = build_faces
    tris  = faces.select { |f| f.length == 3 }
    quads = faces.select { |f| f.length == 4 }
    assert_equal SEGMENTS * SEGMENTS, faces.length,
      "every lat×lon cell must yield a face (pole quads must become triangles, " \
      "not be silently dropped)"
    assert_equal 2 * SEGMENTS, tris.length, "both pole bands must be triangles"
    assert_equal SEGMENTS * (SEGMENTS - 2), quads.length
  end

  def test_sphere_face_mesh_is_manifold
    edge_use = Hash.new(0)
    build_faces.each do |pts|
      ring = pts.map { |p| rounded(p) }
      ring.each_with_index do |a, i|
        b = ring[(i + 1) % ring.length]
        edge_use[[a, b].sort] += 1
      end
    end
    bad = edge_use.reject { |_edge, n| n == 2 }
    assert_empty bad,
      "manifold mesh: every edge must be shared by exactly 2 faces; " \
      "#{bad.length} edges violate this"
  end

  def test_sphere_reaches_both_poles
    zs = build_faces.flatten(1).map { |p| p[2] }
    assert_in_delta 0.0, zs.min, 1e-9, "south pole must be present in the mesh"
    assert_in_delta 4.0, zs.max, 1e-9, "north pole must be present in the mesh"
  end
end
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `ruby test/test_geometry_builders.rb`
Expected: FAIL — 224 грани вместо 256, 0 треугольников, полюсные рёбра встречаются 1 раз, `zs.max ≈ 3.96` (грид без полюсов).

- [ ] **Step 3: Фикс `build_sphere`**

В `handlers/geometry.rb` заменить цикл граней (строки 168-181, от `(0...segments).each do |lat_i|` до закрывающего `end` этого цикла) на:

```ruby
        (0...segments).each do |lat_i|
          (0...segments).each do |lon_i|
            i1 = lat_i * (segments + 1) + lon_i
            i2 = i1 + 1
            i3 = i1 + segments + 1
            i4 = i3 + 1
            begin
              if lat_i == 0
                # Северная полярная полоса: p1 и p2 — обе копии полюса
                # (sin 0 = 0) ⇒ квад вырожден. Явный треугольник
                # полюс → две точки первого кольца. Deep-research T-02.
                group.entities.add_face(points[i1], points[i4], points[i3])
              elsif lat_i == segments - 1
                # Южная полоса: p3/p4 — копии южного полюса (sin π ≈ 1e-16).
                group.entities.add_face(points[i1], points[i2], points[i4])
              else
                group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
              end
            rescue StandardError => e
              # Последний рубеж: не должен срабатывать для сфер — полюсные
              # вырождения обработаны выше явными треугольниками.
              MCPforSketchUp::Core::Logger.log("DEBUG",
                "build_sphere: skipped degenerate face at pole: #{e.class}: #{e.message}")
            end
          end
        end
```

- [ ] **Step 4: Зелёный прогон**

Run: `ruby test/test_geometry_builders.rb && ruby test/run_all.rb`
Expected: PASS / 0 failures по всей сьюте.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb test/test_geometry_builders.rb
git commit -m "fix: build_sphere emits pole triangles — spheres are now manifold (booleans/exports work)"
```

---

### Task 6: `transform_component.position` — абсолютная семантика (T-04)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb:76-109` (transform_component + новый pure-хелпер `position_delta`)
- Modify: `src/sketchup_mcp/tools.py:119-135` (докстринг transform_component)
- Modify: `src/sketchup_mcp/prompts.py` (§3 Conventions)
- Modify: `examples/smoke_check.py:125-126` (шаг 6: комментарий + поведенческий ассерт)
- Create: `test/test_transform_absolute.rb`

**Interfaces:**
- Consumes: `entity.bounds.min` (`.x/.y/.z`, parent-frame), `entity.transform!(Geom::Transformation.translation(Geom::Point3d.new(dx, dy, dz)))`.
- Produces: **решение пользователя (зафиксировано 2026-07-02): вариант (б) отчёта — абсолютная семантика.** `position` = абсолютная цель для МИНИМАЛЬНОГО угла bbox (тот же якорь, что у `create_component`; подтверждено живьём: position — bbox-min, не центр). Ruby переводит в дельту `target − bounds.min`. `rotation`/`scale` НЕ трогаем (остаются относительными вокруг центра bbox). Wire-имя параметра `position` сохраняется. Новый pure-хелпер: `Geometry.position_delta(current_min, target) → [dx, dy, dz]` (числа в дюймах, но функция единиц не знает). Это ПОВЕДЕНЧЕСКИЙ BREAKING CHANGE для сценариев, полагавшихся на relative-сдвиг; до фикса два вызова `position=[100,0,0]` смещали суммарно на 200 мм (подтверждено живьём).

- [ ] **Step 1: Написать падающий тест — создать `test/test_transform_absolute.rb`**

Полное содержимое файла:

```ruby
# test/test_transform_absolute.rb
#
# T-04: position в transform_component — АБСОЛЮТНАЯ цель bbox-min (решение
# от 2026-07-02), а не относительный сдвиг. Pure-хелпер position_delta
# тестируется напрямую; вызов из transform_component закреплён source-guard'ом
# (полный поведенческий прогон хендлера требует модельных стабов; живой пин —
# шаг 6 smoke-матрицы, см. examples/smoke_check.py).
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"

class TestTransformAbsolute < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry
  FakePoint = Struct.new(:x, :y, :z)

  def test_position_delta_moves_bbox_min_to_target
    delta = GEO.position_delta(FakePoint.new(10.0, 20.0, 30.0), [15.0, 20.0, 25.0])
    assert_equal [5.0, 0.0, -5.0], delta
  end

  def test_position_delta_is_zero_when_already_at_target
    delta = GEO.position_delta(FakePoint.new(1.5, 2.5, 3.5), [1.5, 2.5, 3.5])
    assert_equal [0.0, 0.0, 0.0], delta
  end

  def test_position_delta_from_origin_equals_target
    # Совместимость: для entity в начале координат абсолютный и относительный
    # сдвиг совпадают (поэтому старые smoke-прогоны на кубах у origin зелёные).
    delta = GEO.position_delta(FakePoint.new(0.0, 0.0, 0.0), [7.0, 8.0, 9.0])
    assert_equal [7.0, 8.0, 9.0], delta
  end

  # Source-guard: transform_component обязан идти через position_delta
  # (перевод цели в дельту), а не транслировать сырым position-вектором
  # (старая relative-семантика).
  def test_transform_component_translates_via_position_delta
    src = File.read(File.expand_path(
      "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb", __dir__))
    body = src[/def self\.transform_component.*?(?=\n      def self\.)/m]
    refute_nil body, "transform_component body not found"
    assert_match(/position_delta\(entity\.bounds\.min,\s*position\)/, body,
      "position must be converted to a delta from bounds.min (absolute semantics)")
    refute_match(/translation\(\s*\n?\s*Geom::Point3d\.new\(position\[0\]/m, body,
      "raw position must NOT be used as a translation vector (relative semantics)")
  end
end
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `ruby test/test_transform_absolute.rb`
Expected: FAIL — `NoMethodError: undefined method 'position_delta'` + красный source-guard.

- [ ] **Step 3: Фикс Ruby**

В `handlers/geometry.rb`:

(a) Заменить NOTE-комментарий и position-ветку `transform_component` (строки 76-95). Комментарий перед методом:

```ruby
      # NOTE: transform_component on a ComponentInstance modifies ONLY the
      # selected instance (its transformation matrix), not the underlying
      # ComponentDefinition. Other instances of the same definition are
      # unchanged. To modify the definition, use eval_ruby.
      #
      # `position` — АБСОЛЮТНАЯ цель (T-04, решение 2026-07-02): entity
      # переносится так, чтобы минимальный угол его bbox оказался ровно в
      # заданной точке (тот же якорь, что у create_component.position).
      # rotation/scale остаются относительными, вокруг центра bbox.
```

ветку `if position` внутри метода заменить на:

```ruby
          if position
            delta = position_delta(entity.bounds.min, position)
            entity.transform!(Geom::Transformation.translation(
              Geom::Point3d.new(delta[0], delta[1], delta[2])))
          end
```

(b) В секцию `# ----- private builders ---` первым методом добавить:

```ruby
      # Pure math (юнит-тестится без SketchUp): вектор переноса, доставляющий
      # bbox-min `current_min` в точку `target`. Оба аргумента — в дюймах.
      def self.position_delta(current_min, target)
        [target[0] - current_min.x,
         target[1] - current_min.y,
         target[2] - current_min.z]
      end
```

- [ ] **Step 4: Зелёный Ruby-прогон**

Run: `ruby test/test_transform_absolute.rb && ruby test/run_all.rb`
Expected: PASS / 0 failures.

- [ ] **Step 5: Докстринг Python-обёртки**

В `src/sketchup_mcp/tools.py` заменить докстринг `transform_component` (строка 127, однострочный `"""Transform a component's position, rotation, or scale."""`) на:

```python
    """Move, rotate and/or scale a group or component (mm / degrees).

    - position: ABSOLUTE target for the entity's bounding-box MIN corner,
      in mm. The entity is translated so bbox-min lands exactly at
      [x, y, z] — the same anchor create_component uses. It is NOT a
      relative offset: repeating the same position is idempotent.
    - rotation: RELATIVE rotation in degrees around the bbox center,
      applied sequentially about world X, then Y, then Z.
    - scale: RELATIVE scale factors about the bbox center.

    Returns {id, name, type, bbox_mm} — read bbox_mm to verify the result.
    """
```

- [ ] **Step 6: prompts.py §3**

В `src/sketchup_mcp/prompts.py` в раздел `# 3. Conventions` после строки про градусы (`- ALL angles are degrees.`) добавить:

```python
- transform_component.position is an ABSOLUTE target: the entity's
  bbox-min corner lands exactly there (same anchor as
  create_component.position). rotation/scale are relative, about the
  bbox center.
```

- [ ] **Step 7: smoke_check шаг 6 — комментарий стал правдой + поведенческий ассерт**

В `examples/smoke_check.py` заменить шаг 6 (строки 125-126):

```python
        step = 6; print(f"[{step}] transform_component — move id1 to (200,0,0) [ABSOLUTE bbox-min]")
        t1 = parse(await call(conn, "transform_component", id=id1, position=[200, 0, 0]))
        assert abs(t1["bbox_mm"]["min"][0] - 200) < 0.5, \
            f"absolute position semantics broken (T-04): {t1['bbox_mm']}"
```

- [ ] **Step 8: Python-прогон**

Run: `uv run pytest tests/ -q`
Expected: 132 passed (докстринги/промпт схем не ломают; `tests/test_smoke_helpers.py` импортирует smoke-модуль — синтаксис проверится).

- [ ] **Step 9: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb \
        test/test_transform_absolute.rb src/sketchup_mcp/tools.py \
        src/sketchup_mcp/prompts.py examples/smoke_check.py
git commit -m "feat!: transform_component position is an absolute bbox-min target (was: undocumented relative offset)"
```

---

### Task 7: Joints — построение в правильной системе координат (T-03)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb:271-354` (`carve_tails`, `carve_pins`, `carve_board1_fingers` + новый общий хелпер)
- Create: `test/test_joints_frame_compensation.rb`

**Interfaces:**
- Consumes: паттерн `place_tenon` (joints.rb:205-239) — прототип в world-frame scratch-группе → `prot.transform!(board.transformation.inverse)` → `entities.add_instance(prot.definition, prot.transformation)` → `ensure prot.erase!`; `E.entity_collection(board)`, `E.active_model!.active_entities`, `subtract_tracked(cutter, target)` (статистика cut'ов, receiver — cutter).
- Produces: новый приватный хелпер `Joints.add_parent_frame_prototype(board) { |prot| ... }`, инкапсулирующий паттерн; три carve-хелпера строят геометрию через него. Механика бага: хелперы клали геометрию в board-ЛОКАЛЬНУЮ коллекцию (`E.entity_collection(board)`), считая координаты от `board.bounds.center` (РОДИТЕЛЬСКИЙ фрейм) → двойное смещение на величину трансформации доски; живьём: доска `x 800..920`, хвосты улетели в `x 800..1704`, `boolean_cuts.failed=0` рапортовал ложный успех. Бьёт ТОЛЬКО по доскам, трансформированным ПОСЛЕ создания (`create_component` строит геометрию в мировых координатах с identity-трансформацией — поэтому smoke на кубах у origin проходил). Соседние `place_tenon`/`carve_board2_slots` уже корректны — их НЕ трогать.

- [ ] **Step 1: Написать падающий тест — создать `test/test_joints_frame_compensation.rb`**

Полное содержимое файла:

```ruby
# test/test_joints_frame_compensation.rb
#
# T-03: carve_tails / carve_pins / carve_board1_fingers обязаны компенсировать
# трансформацию доски (паттерн place_tenon), иначе геометрия джойнта улетает
# на |translation| от сдвинутой доски (живьём: промах ~1 м при сдвиге +800 мм).
#
# Фейки — translation-only алгебра: transform! складывает векторы, inverse
# отрицает. Ассерт вычисляет ЭФФЕКТИВНУЮ мировую X-координату каждой точки
# (board.T + instance.T + вложенные группы + сырая координата) и требует,
# чтобы геометрия осталась в мировом bbox доски ± глубина реза. Ассерт
# устойчив к обоим вариантам внутреннего устройства (старому add_group-пути
# и новому add_instance-пути) — красный/зелёный решает только СЕМАНТИКА.
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointsFrameCompensation < Minitest::Test
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

  # Translation-only стенд-ин Geom::Transformation.
  class FakeTranslation
    attr_reader :dx, :dy, :dz
    def initialize(dx = 0.0, dy = 0.0, dz = 0.0)
      @dx, @dy, @dz = dx, dy, dz
    end
    def inverse
      FakeTranslation.new(-dx, -dy, -dz)
    end
    def compose(other)
      FakeTranslation.new(dx + other.dx, dy + other.dy, dz + other.dz)
    end
  end

  class FakeFace
    def pushpull(_amount); end
  end

  # Записывает faces / вложенные группы / инстансы — walk-ассерт обходит всё.
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
    attr_reader :entities
    attr_reader :transformation
    def initialize(parent_collection: nil)
      @parent_collection = parent_collection
      @entities = FakeCollection.new
      @transformation = FakeTranslation.new
      @valid = true
    end
    def definition
      @definition ||= Struct.new(:owner).new(self)
    end
    def transform!(t)
      @transformation = @transformation.compose(t)
      self
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def subtract(target)
      TestJointsFrameCompensation.subtract_log << [self, target]
      result = FakeGroup.new(parent_collection: @parent_collection)
      @parent_collection.groups << result if @parent_collection
      erase!
      target.erase! if target.respond_to?(:erase!)
      result
    end
  end

  class FakeBoard < Sketchup::Group
    attr_reader :entities, :bounds, :transformation
    def initialize(bounds:, translation:)
      @entities = FakeCollection.new
      @bounds = bounds
      @transformation = translation
    end
  end

  class FakeModel
    attr_reader :active_entities
    def initialize
      @active_entities = FakeCollection.new
    end
  end

  # Доска, «созданная у origin (x 0..4) и сдвинутая на +30»: мировой bbox
  # x 30..34, transformation.dx = 30 — минимальный слепок живого репро
  # (create_component строит с identity-T, transform_component навешивает T).
  def make_board
    FakeBoard.new(
      bounds: FakeBounds.new(FakePoint.new(30.0, 0.0, 0.0), FakePoint.new(34.0, 4.0, 1.0)),
      translation: FakeTranslation.new(30.0, 0.0, 0.0),
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

  # Эффективные мировые X всех точек, достижимых из коллекции доски.
  def world_xs(board)
    xs = []
    walk = lambda do |coll, offset|
      coll.faces.each { |pts| pts.each { |p| xs << p[0] + offset } }
      coll.groups.each do |g|
        walk.call(g.entities, offset + g.transformation.dx)
      end
      coll.instances.each do |inst|
        walk.call(inst[:definition].owner.entities, offset + inst[:transformation].dx)
      end
    end
    walk.call(board.entities, board.transformation.dx)
    xs
  end

  DEPTH = 0.5

  def assert_geometry_on_board(board, label)
    xs = world_xs(board)
    refute_empty xs, "#{label} must add geometry into the board"
    lo = board.bounds.min.x - DEPTH - 1e-6
    hi = board.bounds.max.x + DEPTH + 1e-6
    assert xs.min >= lo && xs.max <= hi,
      "#{label}: geometry escaped the board's world bbox (got x " \
      "#{xs.min.round(3)}..#{xs.max.round(3)}, allowed #{lo.round(3)}..#{hi.round(3)}) — " \
      "parent-frame coords drawn into board-local entities (T-03)"
  end

  def test_carve_tails_lands_on_translated_board
    board = make_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_tails")
  end

  def test_carve_pins_lands_on_translated_board_and_counts_cuts
    board = make_board
    J.reset_joint_stats!
    J.carve_pins(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_pins")
    assert_equal 3, J.joint_cut_stats["attempted"], "3 tail-slot cuts expected"
    refute_empty self.class.subtract_log, "pins must be carved via Group#subtract"
  end

  def test_carve_board1_fingers_lands_on_translated_board_and_counts_cuts
    board = make_board
    J.reset_joint_stats!
    J.carve_board1_fingers(board, 2.0, 2.0, DEPTH, 5, 0, 0, 0)
    assert_geometry_on_board(board, "carve_board1_fingers")
    assert_equal 2, J.joint_cut_stats["attempted"], "num_fingers/2 cuts expected"
  end

  def test_scratch_prototypes_are_erased_from_model_root
    board = make_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    leftovers = @model.active_entities.groups.select(&:valid?)
    assert_empty leftovers,
      "world-frame scratch group must be erased after instancing (place_tenon pattern)"
  end
end
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `ruby test/test_joints_frame_compensation.rb`
Expected: FAIL — три `assert_geometry_on_board` красные (геометрия на x ≈ 60.7..63.3 при допуске 29.5..34.5 — двойное смещение). `test_scratch_prototypes_are_erased_from_model_root` на старом коде vacuously зелёный (scratch-группы ещё не создаются) — он станет содержательным guard'ом после фикса.

- [ ] **Step 3: Фикс `joints.rb`**

(a) Перед `def self.carve_tails` (строка 271) добавить общий хелпер:

```ruby
      # Строит геометрию в world-frame scratch-группе (координаты — от
      # board.bounds, т.е. РОДИТЕЛЬСКИЙ фрейм) и подсаживает её в доску
      # instance'ом с компенсацией board.transformation.inverse — геометрия
      # оказывается там, где была построена, даже если доску двигали/вращали
      # ПОСЛЕ создания. Паттерн и математика — см. подробный комментарий в
      # place_tenon (T_inst = T_board⁻¹ ⇒ world = parent_t · geom).
      # Deep-research T-03: старый путь рисовал parent-frame координаты прямо
      # в board-ЛОКАЛЬНУЮ коллекцию — двойное смещение на |T_board|.
      def self.add_parent_frame_prototype(board)
        prot = MCPforSketchUp::Helpers::Entities.active_model!.active_entities.add_group
        begin
          yield prot
          prot.transform!(board.transformation.inverse)
          if prot.valid?
            E.entity_collection(board).add_instance(prot.definition, prot.transformation)
          end
        ensure
          prot.erase! if prot && prot.valid?
        end
      end
```

(b) Заменить `carve_tails` (строки 271-289) целиком:

```ruby
      def self.carve_tails(board, width, height, depth, angle_deg, num_tails, ox, oy, oz)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        tail_w = width / (2 * num_tails - 1)
        angle  = angle_deg * Math::PI / 180.0
        bottom_w = tail_w + 2 * depth * Math.tan(angle)

        add_parent_frame_prototype(board) do |prot|
          num_tails.times do |i|
            tx = cx - width/2 + tail_w * 2 * i
            face = prot.entities.add_face(
              [tx - tail_w/2,    cy - height/2, cz],
              [tx + tail_w/2,    cy - height/2, cz],
              [tx + bottom_w/2,  cy - height/2, cz - depth],
              [tx - bottom_w/2,  cy - height/2, cz - depth])
            face.pushpull(height)
          end
        end
      end
```

(c) Заменить `carve_pins` (строки 291-322) целиком:

```ruby
      def self.carve_pins(board, width, height, depth, angle_deg, num_tails, ox, oy, oz)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        tail_w = width / (2 * num_tails - 1)
        angle  = angle_deg * Math::PI / 180.0
        bottom_w = tail_w + 2 * depth * Math.tan(angle)

        add_parent_frame_prototype(board) do |prot|
          pin_group = prot.entities.add_group
          face = pin_group.entities.add_face(
            [cx - width/2, cy - height/2, cz],
            [cx + width/2, cy - height/2, cz],
            [cx + width/2, cy + height/2, cz],
            [cx - width/2, cy + height/2, cz])
          face.pushpull(depth)

          num_tails.times do |i|
            break unless pin_group.valid?  # if a previous subtract returned nil, stop
            tx = cx - width/2 + tail_w * 2 * i
            cutter = prot.entities.add_group
            cf = cutter.entities.add_face(
              [tx - tail_w/2,    cy - height/2, cz],
              [tx + tail_w/2,    cy - height/2, cz],
              [tx + bottom_w/2,  cy - height/2, cz - depth],
              [tx - bottom_w/2,  cy - height/2, cz - depth])
            cf.pushpull(height)
            # Group#subtract reversed semantics: cutter.subtract(pin_group) returns
            # pin_group - cutter (= pin with tail slot carved). Both groups erased.
            new_pin = subtract_tracked(cutter, pin_group)
            pin_group = new_pin if new_pin
          end
        end
      end
```

(d) Заменить `carve_board1_fingers` (строки 324-354) целиком:

```ruby
      def self.carve_board1_fingers(board, width, height, depth, num_fingers, ox, oy, oz)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        # Use float division — Integer / Integer would truncate at 0 for small inputs
        finger_w = width / num_fingers.to_f

        add_parent_frame_prototype(board) do |prot|
          group = prot.entities.add_group
          face = group.entities.add_face(
            [cx - width/2, cy - height/2, cz],
            [cx + width/2, cy - height/2, cz],
            [cx + width/2, cy + height/2, cz],
            [cx - width/2, cy + height/2, cz])
          # Extrude FIRST: face reference would be invalidated by subsequent
          # Group#subtract operations below, so push before the loop runs.
          face.pushpull(depth)
          (num_fingers / 2).times do |i|
            break unless group.valid?
            tx = cx - width/2 + finger_w * (2 * i + 1)
            cutter = prot.entities.add_group
            cf = cutter.entities.add_face(
              [tx - finger_w/2, cy - height/2, cz],
              [tx + finger_w/2, cy - height/2, cz],
              [tx + finger_w/2, cy + height/2, cz],
              [tx - finger_w/2, cy + height/2, cz])
            cf.pushpull(depth)
            # cutter.subtract(group) returns group - cutter (board1 with finger slot).
            new_group = subtract_tracked(cutter, group)
            group = new_group if new_group
          end
        end
      end
```

- [ ] **Step 4: Зелёный прогон**

Run: `ruby test/test_joints_frame_compensation.rb && ruby test/run_all.rb`
Expected: PASS / 0 failures (в т.ч. source-guard'ы задачи 4: call-sites `subtract_tracked(cutter, pin_group)` / `(cutter, group)` в новом коде сохранены дословно).

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb test/test_joints_frame_compensation.rb
git commit -m "fix: dovetail/finger carve helpers compensate board transformation — joints land on moved/rotated boards"
```

---

### Task 8: `connection.py` — все мутации сокета под одним замком (T-08)

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (`get_connection`, `close_connection`, + методы `ensure_connected`/`aclose`)
- Modify: `src/sketchup_mcp/app.py:38-41` (lifespan eager-connect)
- Modify: `src/sketchup_mcp/tools.py:45` (комментарий)
- Modify: `tests/test_connection.py` (2 переписать, 2 добавить)
- Modify: `tests/test_app.py` (1 добавить)

**Interfaces:**
- Consumes: `SketchUpConnection._lock` (единственный инстансный замок `send_command`), `_connect_or_raise()` (уже переводит `OSError → ConnectionError`), `disconnect()`.
- Produces: инвариант «`_reader`/`_writer` мутируются ТОЛЬКО под `self._lock`»: `get_connection()` больше НЕ коннектит (только создаёт/возвращает singleton под модульным `_get_connection_lock`); новые публичные методы `async ensure_connected()` (eager-connect для lifespan; `ConnectionError` при отказе) и `async aclose()` (закрытие с ожиданием in-flight запроса; используется `close_connection()`). Ленивый connect в `_send_once` (уже под замком) остаётся единственным авто-коннектором. Механика бага: `get_connection` health-check'ал и коннектил под модульным замком, а error-paths `_send_once` звали `disconnect()`, который после await-точки (`wait_closed`) безусловно нулил `_reader/_writer` — интерливинг терял свежую пару соседа (ложные `-32603 internal: reader is None`) или утекал сокетом (зомби-клиент на Ruby-стороне до ~2 ч SO_KEEPALIVE).

- [ ] **Step 1: Написать падающие тесты**

(a) В `tests/test_connection.py` ЗАМЕНИТЬ тест `test_get_connection_raises_connection_error_when_refused` (строки 381-394) на два:

```python
async def test_get_connection_does_not_open_socket(monkeypatch):
    """T-08: get_connection только создаёт/возвращает singleton. Любой connect
    живёт под conn._lock (ensure_connected / ленивый _send_once) — иначе
    disconnect() параллельного send_command гонялся бы с ним за _reader/_writer."""
    from sketchup_mcp import connection as conn_module

    monkeypatch.setattr(conn_module, "_connection", None)
    with patch(
        "sketchup_mcp.connection.asyncio.open_connection",
        side_effect=AssertionError("get_connection must not connect"),
    ):
        conn = await conn_module.get_connection()
    assert conn._writer is None
    monkeypatch.setattr(conn_module, "_connection", None)


async def test_ensure_connected_raises_connection_error_when_refused(monkeypatch):
    """Отказ TCP теперь всплывает из ensure_connected (как раньше из get_connection)."""
    from sketchup_mcp import connection as conn_module

    monkeypatch.setattr(conn_module, "_connection", None)
    with patch(
        "sketchup_mcp.connection.asyncio.open_connection",
        side_effect=ConnectionRefusedError("nope"),
    ):
        conn = await conn_module.get_connection()
        with pytest.raises(ConnectionError) as exc_info:
            await conn.ensure_connected()
    assert "cannot reconnect" in str(exc_info.value)
    monkeypatch.setattr(conn_module, "_connection", None)
```

(b) Там же ПЕРЕПИСАТЬ `test_get_connection_cold_start_race_creates_singleton_once`: внутри `with patch(...)` блока заменить создание задач так, чтобы каждый caller делал `get_connection()` + `ensure_connected()` (семантика eager-connect переехала):

```python
        async def cold_caller():
            conn = await conn_module.get_connection()
            await conn.ensure_connected()
            return conn

        t1 = asyncio.create_task(cold_caller())
        t2 = asyncio.create_task(cold_caller())
```

(остальное тело теста — gate, `open_call_count == 1`, `c1 is c2`, cleanup — без изменений).

(c) Там же ДОБАВИТЬ детерминированный тест несмешиваемости close/reconnect:

```python
async def test_aclose_cannot_clobber_concurrent_reconnect():
    """Регрессия T-08. Старый код: disconnect() после await wait_closed
    БЕЗУСЛОВНО нулил _reader/_writer и мог затереть свежую пару, открытую
    параллельным connect'ом из-под другого замка. Теперь aclose() и
    ensure_connected() сериализованы одним conn._lock: закрытие завершается
    ДО реконнекта, свежая пара выживает."""
    conn = SketchUpConnection(host="127.0.0.1", port=1, timeout=1.0)

    gate = asyncio.Event()
    old_writer = MagicMock()
    old_writer.close = MagicMock()

    async def slow_wait_closed():
        await gate.wait()

    old_writer.wait_closed = slow_wait_closed
    old_writer.is_closing = MagicMock(return_value=False)
    conn._reader = asyncio.StreamReader()
    conn._writer = old_writer

    fresh_reader = asyncio.StreamReader()
    fresh_writer = MagicMock()
    fresh_writer.is_closing = MagicMock(return_value=False)

    async def fake_connect():
        conn._reader = fresh_reader
        conn._writer = fresh_writer

    conn.connect = fake_connect

    close_task = asyncio.create_task(conn.aclose())
    await asyncio.sleep(0)   # aclose взял lock и повис в wait_closed
    reconnect_task = asyncio.create_task(conn.ensure_connected())
    await asyncio.sleep(0)   # ensure_connected ждёт lock
    gate.set()
    await asyncio.gather(close_task, reconnect_task)

    assert conn._writer is fresh_writer, "reconnect's fresh pair must survive aclose"
    assert conn._reader is fresh_reader
```

(d) В `tests/test_app.py` добавить тест нового eager-connect пути:

```python
async def test_lifespan_degrades_when_eager_connect_fails(monkeypatch):
    """Eager-connect теперь двухфазный: get_connection() отдаёт singleton,
    ensure_connected() коннектит под инстансным замком. Отказ второй фазы
    так же деградирует, а не роняет старт."""
    class FakeConn:
        async def ensure_connected(self):
            raise ConnectionError("refused")

    async def fake_get():
        return FakeConn()

    async def fake_close():
        pass

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", fake_get)
    monkeypatch.setattr(app_module, "close_connection", fake_close)

    async with app_module.server_lifespan(app_module.mcp) as state:
        assert state == {}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `uv run pytest tests/test_connection.py tests/test_app.py -q`
Expected: новые/переписанные тесты красные (`AttributeError: ... no attribute 'ensure_connected'/'aclose'`; `test_get_connection_does_not_open_socket` падает AssertionError из патча — текущий get_connection коннектит).

- [ ] **Step 3: Реализация в `connection.py`**

(a) После метода `disconnect` (за строкой 203) добавить два метода:

```python
    async def ensure_connected(self) -> None:
        """Открыть сокет (и выполнить handshake), если он ещё не открыт.

        Берёт тот же ``self._lock``, что и ``send_command`` — ЕДИНСТВЕННЫЙ
        замок, под которым мутируются ``_reader``/``_writer`` (T-08:
        connect из get_connection под модульным замком гонялся с
        ``disconnect()`` внутри in-flight ``send_command`` — терял свежую
        пару сокетов или утекал соединением).

        Raises ``ConnectionError`` при сетевом отказе (как раньше поднимал
        ``get_connection``) — lifespan ловит и стартует degraded.
        """
        async with self._lock:
            if self._writer is None or self._writer.is_closing():
                await self._connect_or_raise()

    async def aclose(self) -> None:
        """Закрыть сокет под ``self._lock`` — дождавшись in-flight запроса."""
        async with self._lock:
            await self.disconnect()
```

(b) Заменить `get_connection` (строки 381-405) на:

```python
async def get_connection() -> SketchUpConnection:
    """Singleton accessor — только создаёт/возвращает объект, НЕ коннектит.

    Коннект выполняется исключительно под инстансным ``conn._lock``: лениво
    в ``_send_once`` или явно через ``ensure_connected()`` (eager-connect в
    lifespan). Раньше здесь жил health-check + connect под модульным
    ``_get_connection_lock`` — он гонялся с ``disconnect()`` параллельного
    ``send_command`` (T-08/PY-CONN-01): ложные «internal: reader is None»
    и утечка сокетов при рестарте SketchUp.
    """
    global _connection
    async with _get_connection_lock:
        if _connection is None:
            _connection = SketchUpConnection(
                host=config.HOST, port=config.PORT, timeout=config.TIMEOUT
            )
        return _connection
```

(c) Заменить `close_connection`:

```python
async def close_connection() -> None:
    """Close and forget the module singleton (ждёт in-flight запрос под conn._lock)."""
    global _connection
    if _connection is not None:
        await _connection.aclose()
        _connection = None
```

- [ ] **Step 4: `app.py` lifespan**

Заменить (строки 38-41):

```python
    try:
        await get_connection()
    except (ConnectionError, SketchUpError) as e:
        logger.warning(f"Could not connect on startup: {e}")
```

на:

```python
    try:
        conn = await get_connection()
        await conn.ensure_connected()
    except (ConnectionError, SketchUpError) as e:
        logger.warning(f"Could not connect on startup: {e}")
```

- [ ] **Step 5: Комментарий в `tools.py`**

Строку 45 (`sketchup = await get_connection()              # may raise ConnectionError`) заменить на:

```python
    sketchup = await get_connection()
    # ConnectionError при недоступном SketchUp поднимает send_command
    # (ленивый connect под conn._lock, T-08), не get_connection — callers
    # ловят её как раньше.
    return await sketchup.send_command(tool_name, kwargs)  # raises SketchUpError
```

(строку `return await sketchup.send_command(...)` не дублировать — это замена пары строк 45-46).

- [ ] **Step 6: Зелёный прогон**

Run: `uv run pytest tests/ -q`
Expected: все passed (136+). Если какой-то ещё тест мокал старое поведение `get_connection`-connects — поправить его мок по образцу шага 1b (двухфазный `get_connection` + `ensure_connected`).

- [ ] **Step 7: Commit**

```bash
git add src/sketchup_mcp/connection.py src/sketchup_mcp/app.py src/sketchup_mcp/tools.py \
        tests/test_connection.py tests/test_app.py
git commit -m "fix: serialize all socket mutation under the connection lock — get_connection no longer connects (races disconnect)"
```

---

### Task 9: Расширить smoke-матрицу (T-24)

**Files:**
- Modify: `examples/smoke_check.py` (3 новых шага, ренумерация 20-22 → 23-25, docstring, финальный вывод, stale-комментарий)
- Modify: `CLAUDE.md` (строка про 22-step)

**Interfaces:**
- Consumes: фиксы задач 3 (eval-ошибка быстрая), 5 (сфера manifold), 6 (absolute position), 7 (joints на сдвинутой доске); хелперы smoke: `call()`, `parse()`, `_maybe_skip_eval()`, `eval_skipped`, `SketchUpError`.
- Produces: 25-шаговый smoke, покрывающий ровно те пути, где жили все три live-подтверждённых major'а (до сих пор все четыре create в smoke были кубами у origin). Прогон живой (требует SketchUp 2026 + пересобранный плагин) — это definition of done для T-01/T-02/T-03 после установки обновлённого `.rbz`.

- [ ] **Step 1: Импорт time + docstring**

В `examples/smoke_check.py`: в блок импортов (после `import sys`) добавить `import time`. В docstring файла заменить строку `1. SketchUp 2024+ is running with an empty model.` на:

```
  1. SketchUp 2026+ is running with an empty model (step 19 uses the
     viewport-screenshot tool, verified on SketchUp 2026 only).
```

- [ ] **Step 2: Три новых шага**

После шага 19 (блок `get_viewport_screenshot`, перед комментарием `# NB: cleanup must precede undo.`) вставить:

```python
        step = 20; print(f"[{step}] sphere d=100 — manifold poles + boolean union (T-02)")
        sph = parse(await call(conn, "create_component",
                               type="sphere", position=[400, 0, 0],
                               dimensions=[100, 100, 100]))
        id_sph = sph["id"]
        zspan = sph["bbox_mm"]["max"][2] - sph["bbox_mm"]["min"][2]
        assert abs(zspan - 100) < 0.5, (
            f"sphere z-span {zspan}mm — poles cut off => non-manifold generator (T-02)")
        cub = parse(await call(conn, "create_component",
                               type="cube", position=[450, 50, 0],
                               dimensions=[100, 100, 100]))
        id_cub = cub["id"]
        # До фикса T-02 этот union падал с -32603 "likely non-manifold".
        uni = parse(await call(conn, "boolean_operation",
                               target_id=id_sph, tool_id=id_cub, operation="union"))
        id_sph_union = uni["id"]  # операнды копируются; originals живы

        step = 21; print(f"[{step}] dovetail on a TRANSLATED board (T-03)")
        b_tail = parse(await call(conn, "create_component",
                                  type="cube", dimensions=[120, 100, 20]))["id"]
        moved = parse(await call(conn, "transform_component",
                                 id=b_tail, position=[800, 0, 0]))
        assert abs(moved["bbox_mm"]["min"][0] - 800) < 0.5, f"move failed: {moved}"
        b_pin = parse(await call(conn, "create_component",
                                 type="cube", position=[800, 120, 0],
                                 dimensions=[120, 100, 20]))["id"]
        dv = parse(await call(conn, "create_dovetail",
                              tail_id=b_tail, pin_id=b_pin,
                              width=50, height=50, depth=15))
        assert dv["boolean_cuts"]["failed"] == 0, f"dovetail cuts failed: {dv['boolean_cuts']}"
        # До фикса T-03 хвосты улетали на величину сдвига (живьём: x до 1704
        # при доске 800..920) — bbox обеих досок обязан остаться в объёме
        # доски ± глубина соединения.
        for key in ("tail", "pin"):
            bb = dv[key]["bbox_mm"]
            assert bb["min"][0] >= 800 - 15 - 1 and bb["max"][0] <= 920 + 15 + 1, (
                f"{key} board bbox {bb} escaped the board volume — "
                f"frame-compensation regression (T-03)")
        b_tail, b_pin = dv["tail"]["id"], dv["pin"]["id"]

        step = 22; print(f"[{step}] eval_ruby syntax error — fast diagnostic, not a 60s hang (T-01)")
        t0 = time.monotonic()
        try:
            raw = await _maybe_skip_eval(
                "eval_ruby step 22 (syntax error)",
                call(conn, "eval_ruby", code="def broken("),
            )
            if raw is None:
                eval_skipped[0] += 1
            else:
                raise AssertionError(f"syntax error must raise an error, got: {raw}")
        except SketchUpError as e:
            elapsed = time.monotonic() - t0
            assert e.code == -32603, f"expected -32603, got [{e.code}] {e.message}"
            assert "SyntaxError" in e.message, f"no parser diagnostic in: {e.message}"
            assert elapsed < 10, f"took {elapsed:.1f}s — looks like the old 60s hang (T-01)"
            print(f"    ✓ SyntaxError surfaced in {elapsed:.2f}s")
```

- [ ] **Step 3: Ренумерация хвоста + cleanup**

Старые шаги 20/21/22 становятся 23/24/25 (`step = 23` cleanup, `step = 24` undo, `step = 25` version handshake — поправить и литералы в `print`). Список cleanup расширить:

```python
        for cid in [id_bool, b_mortise, b_tenon,
                    id_sph, id_cub, id_sph_union, b_tail, b_pin]:
```

Финальный вывод заменить на:

```python
        print(f"Smoke complete: 25 steps total, {eval_skipped[0]} skipped (eval gate closed)")
```

Комментарий `# Remove this block once chamfer/fillet debugging is complete.` (в except-блоке `main`) заменить на `# Kept permanently: smoke failures need the Ruby-side backtrace for diagnosis.`

- [ ] **Step 4: Синтаксис + юнит-прогон**

Run: `uv run python -c "import ast; ast.parse(open('examples/smoke_check.py').read())" && uv run pytest tests/ -q`
Expected: без исключений; pytest зелёный (`tests/test_smoke_helpers.py` импортирует модуль smoke).

- [ ] **Step 5: Обновить упоминание 22-step**

В `CLAUDE.md` (раздел Development Commands) заменить `python examples/smoke_check.py # 22-step end-to-end (covers all handlers)` на `python examples/smoke_check.py # 25-step end-to-end (covers all handlers)`. Проверить README: `grep -n "22" README.md` — если есть упоминание шагов smoke, обновить аналогично.

- [ ] **Step 6: Commit**

```bash
git add examples/smoke_check.py CLAUDE.md README.md
git commit -m "test: extend smoke matrix — manifold sphere + union, dovetail on translated board, fast eval syntax-error (T-24)"
```

---

### Task 10: Финальная верификация и актуализация доков

**Files:**
- Modify: `CLAUDE.md` (счётчики тестов), `README.md` (счётчик Python/Ruby тестов, если упомянут)

**Interfaces:**
- Consumes: все предыдущие задачи закоммичены.
- Produces: зелёные сьюты; доки не врут о счётчиках; чистый лог ветки.

- [ ] **Step 1: Полные прогоны**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q`
Expected: 0 failures / all passed. Зафиксировать фактические числа (runs/assertions Ruby; passed Python).

- [ ] **Step 2: Обновить счётчики в доках**

В `CLAUDE.md` строки `ruby test/run_all.rb           # Ruby (minitest, stdlib only) — 327 runs / 844 assertions` и `uv run pytest tests/ -q        # Python (pytest) — 132 tests` заменить фактическими числами из шага 1. `grep -n "327\|844\|132" README.md CLAUDE.md` — обновить все совпадения-счётчики (не трогая несвязанные числа).

- [ ] **Step 3: Санити ветки**

Run: `git log --oneline master..HEAD`
Expected: ~11 коммитов (план + 10 задач), каждый — одна задача. `git status` чист (кроме заведомо untracked мусора рабочего дерева: `.gemini/`, `diff.patch`, `docs/session-transfer-*`, `docs/superpowers/` вне плана).

- [ ] **Step 4: Commit доков**

```bash
git add CLAUDE.md README.md
git commit -m "docs: refresh test-suite counters after P1 fix batch"
```

---

## После плана (вне задач — заметки исполнителю и владельцу)

1. **Живой DoD для T-01/T-02/T-03:** пересобрать плагин (`cd mcp_for_sketchup && ruby package.rb --variant=warehouse`), установить `.rbz` в SketchUp 2026, перезапустить сервер плагина и прогнать `uv run python examples/smoke_check.py` — все 25 шагов зелёные. Это ручной шаг (нужен живой SketchUp).
2. **Перед созданием PR:** по конвенции проекта `git rm -r docs/superpowers/ && git commit` — план не должен попасть в diff PR (останется в истории ветки).
3. **При следующем релизе** (docs/release.md): подумать о поднятии MIN_PYTHON (Ruby) / MIN_RUBY (Python) floor'ов — семантика `position` изменилась, смешение старого клиента с новым сервером (и наоборот) даст тихие промахи позиционирования.
4. **Не в этом плане:** T-05/T-07 (LLM-контракт: докстринги всех 22 тулов, пагинация интроспекции) — следующий план; P2-батч (T-06, T-11…T-29) и P3 — по карте тикетов отчёта. Продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки) — принять до сабмита в Extension Warehouse.

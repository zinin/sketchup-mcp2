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
  # NB: намеренный literal-пин — regex извлечения тела зависит от
  # 6-пробельной индентации и наличия следующего def self. Переформатирование
  # красит тест; обновить пин осознанно, не «чинить» стиль под форматтер.
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

# ---------------------------------------------------------------------------
# Поведенческий fake-тест хендлера transform_component (дополнение по ревью):
# position-путь целиком — mm→inch на границе, дельта от bounds.min, ровно
# один transform! с translation-вектором. Фейки — по образцу
# test_boolean_direction.rb (guarded-стабы + Method-object save/restore для
# Entities.active_model!); Geom::Transformation.translation патчится в
# setup/teardown по конвенции runtime-патча из test_helpers_geometry.rb.
# ---------------------------------------------------------------------------

require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"

module Sketchup
  class Group; end unless defined?(Group)
end

# Guarded-минимум для standalone-прогона; в run_all другие файлы уже
# определили более богатые версии (reopen не происходит — guard пропускает).
module Geom
  unless defined?(Point3d)
    class Point3d
      attr_reader :x, :y, :z
      def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
    end
  end
  unless defined?(Transformation)
    class Transformation; end
  end
end

class TestTransformComponentHandler < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry
  EH  = MCPforSketchUp::Helpers::Entities

  FakePoint = Struct.new(:x, :y, :z)
  # Маркер, который наш стаб Geom::Transformation.translation возвращает
  # вместо настоящей трансформации — несёт вектор для ассертов.
  TranslationMarker = Struct.new(:x, :y, :z)

  class FakeBounds
    attr_reader :min, :max
    def initialize(min, max)
      @min, @max = min, max
    end
    def center
      FakePoint.new((min.x + max.x) / 2.0, (min.y + max.y) / 2.0, (min.z + max.z) / 2.0)
    end
  end

  class FakeEntity < Sketchup::Group
    attr_reader :bounds, :transforms
    def initialize(bounds)
      @bounds = bounds
      @transforms = []
    end
    def transform!(t)
      @transforms << t
      self
    end
    def valid?; true; end
    def entityID; 4242; end
    def name; "fake_entity"; end
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
    # bounds.min = (10, 0, 0) ДЮЙМОВ — entity заведомо не в origin, чтобы
    # абсолютная семантика (дельта 15−10=5) отличалась от старой
    # относительной (сдвиг на все 15).
    bounds = FakeBounds.new(FakePoint.new(10.0, 0.0, 0.0),
                            FakePoint.new(14.0, 4.0, 4.0))
    @entity = FakeEntity.new(bounds)
    model = FakeModel.new(4242 => @entity)

    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }

    @saved_translation =
      if Geom::Transformation.respond_to?(:translation)
        Geom::Transformation.method(:translation)
      end
    Geom::Transformation.define_singleton_method(:translation) do |point|
      TranslationMarker.new(point.x, point.y, point.z)
    end
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
    if @saved_translation
      Geom::Transformation.define_singleton_method(:translation, @saved_translation)
    else
      Geom::Transformation.singleton_class.send(:remove_method, :translation)
    end
  end

  def test_position_moves_bbox_min_to_absolute_target
    # 381 мм = ровно 15" (mm→inch на границе хендлера).
    result = GEO.transform_component("id" => 4242, "position" => [381.0, 0.0, 0.0])

    assert_equal 1, @entity.transforms.length,
      "position-only call must issue exactly ONE transform! " \
      "(no rotation/scale branches)"
    t = @entity.transforms.first
    assert_instance_of TranslationMarker, t,
      "the single transform! must come from Geom::Transformation.translation " \
      "(this test stubs only translation — a rotation/scaling transform " \
      "would not produce a TranslationMarker)"
    # Дельта = цель − bounds.min = 15 − 10 дюймов (НЕ сырые 15 relative-семантики).
    assert_equal [5.0, 0.0, 0.0], [t.x, t.y, t.z]
    assert_equal 4242, result["id"], "happy path must commit and describe the entity"
  end
end

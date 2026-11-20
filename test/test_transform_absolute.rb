# test/test_transform_absolute.rb
#
# T-04: position в transform_component — АБСОЛЮТНАЯ цель bbox-min (решение
# от 2026-07-02), а не относительный сдвиг. Block A (M-03): цель — в МИРОВЫХ
# координатах, и для вложенных entity тоже. Дельта берётся от мирового
# bbox-min (bounds через матрицу родителей, Frames.world_box) и переводится в
# систему родителя сопряжением P⁻¹·T·P (Frames.conjugate); rotation и scale —
# вокруг мировых осей через центр мирового bbox, тем же сопряжением.
# Pure-хелпер position_delta тестируется напрямую; вызов из
# transform_component закреплён source-guard'ом; живой пин — шаг 6 и шаг 24
# smoke-матрицы (examples/smoke_check.py).
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "support/frame_fakes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"

class TestTransformAbsolute < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry

  def test_position_delta_moves_bbox_min_to_target
    assert_equal [5.0, 0.0, -5.0], GEO.position_delta([10.0, 20.0, 30.0], [15.0, 20.0, 25.0])
  end

  def test_position_delta_is_zero_when_already_at_target
    assert_equal [0.0, 0.0, 0.0], GEO.position_delta([1.5, 2.5, 3.5], [1.5, 2.5, 3.5])
  end

  def test_position_delta_from_origin_equals_target
    # Совместимость: для entity в начале координат абсолютный и относительный
    # сдвиг совпадают (поэтому старые smoke-прогоны на кубах у origin зелёные).
    assert_equal [7.0, 8.0, 9.0], GEO.position_delta([0.0, 0.0, 0.0], [7.0, 8.0, 9.0])
  end

  # Source-guard: transform_component обязан брать дельту от МИРОВОГО
  # bbox-min и переводить её в систему родителя сопряжением, а не
  # транслировать сырым position-вектором (старая relative-семантика) и не
  # двигать в системе родителя (до block A).
  # NB: намеренный literal-пин — regex извлечения тела зависит от
  # 6-пробельной индентации и наличия следующего def self. Переформатирование
  # красит тест; обновить пин осознанно, не «чинить» стиль под форматтер.
  def test_transform_component_translates_the_world_delta_in_the_parent_frame
    src = File.read(File.expand_path(
      "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb", __dir__), encoding: "UTF-8")
    body = src[/def self\.transform_component.*?(?=\n      def self\.)/m]
    refute_nil body, "transform_component body not found"
    assert_match(/world_min = F\.world_box\(entity\.bounds, parent\)\[0\]/, body,
      "the delta must start from the WORLD bbox-min (bounds through the parents' matrix)")
    assert_match(/delta = position_delta\(world_min, position\)/, body,
      "position must be converted to a delta from the world bbox-min (absolute semantics)")
    assert_match(/F\.conjugate\(F\.translation\(\*delta\), parent\)/, body,
      "the world delta must be conjugated into the parent frame")
    refute_match(/F\.translation\(\*position\)/, body,
      "raw position must NOT be used as a translation vector (relative semantics)")
    refute_match(/Geom::Transformation\.translation/, body,
      "a parent-frame translation would miss the world target of a nested entity")
  end
end

# ---------------------------------------------------------------------------
# Поведенческий fake-тест хендлера transform_component: mm→inch на границе,
# мировой bbox через матрицу родителей, ровно один transform! на шаг. Каждый
# transform! получает Frames.transformation(m); стаб возвращает Marker с
# матрицей m, и тесты проверяют её как условие сопряжения: P·L == W·P, где P —
# матрица родителей, L — записанная матрица, W — мировое действие.
# ---------------------------------------------------------------------------

require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentDefinition; end unless defined?(ComponentDefinition)
end

class TestTransformComponentHandler < Minitest::Test
  include SingletonStubs

  GEO = MCPforSketchUp::Handlers::Geometry
  EH  = MCPforSketchUp::Helpers::Entities
  F   = MCPforSketchUp::Helpers::Frames

  # What the stubbed Frames.transformation returns: the matrix it was given.
  Marker = Struct.new(:matrix)

  # The parents of the nested cases: moved 100" along X and turned 90° about Z.
  ROTATED = F.multiply(F.translation(100, 0, 0), F.rotation([0, 0, 0], 2, 90))

  class FakeEntity < Sketchup::Group
    attr_reader :bounds, :transforms, :parent

    def initialize(bounds, parent)
      @bounds = bounds
      @parent = parent
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
    attr_reader :log
    def initialize(by_id)
      @by_id = by_id
      @log = []
    end
    def start_operation(name, *)
      @log << [:start, name]
      true
    end
    def commit_operation
      @log << :commit
      true
    end
    def abort_operation
      @log << :abort
      true
    end
    def find_entity_by_id(int_id)
      @by_id[int_id]
    end
  end

  def setup
    stub_singleton(F, :transformation) { |m| Marker.new(m) }
  end

  # The entity with `bounds` (inches) in a parent placed at `parent_matrix`
  # (nil: at the top level), registered as entity 4242.
  def place_entity(min, max, parent_matrix = nil)
    parent =
      if parent_matrix
        definition = FrameFakes::Definition.new("Group#1", group: true)
        FrameFakes.place(definition, id: 1, parent: Object.new, matrix: parent_matrix)
        definition
      end
    @entity = FakeEntity.new(FrameFakes.bounds(min, max), parent)
    model = FakeModel.new(4242 => @entity)
    stub_singleton(EH, :active_model!) { model }
    @model = model
    @entity
  end

  def recorded
    assert_equal 1, @entity.transforms.length, "exactly one transform! for one step"
    t = @entity.transforms.first
    assert_instance_of Marker, t, "every transform! must come from Frames.transformation"
    t.matrix
  end

  def assert_matrix(expected, actual, tol = 1e-9)
    expected.each_with_index { |v, i| assert_in_delta v, actual[i], tol, "element #{i} of #{actual.inspect}" }
  end

  def assert_point(expected, actual, tol = 1e-9)
    expected.each_with_index { |v, i| assert_in_delta v, actual[i], tol, "axis #{i} of #{actual.inspect}" }
  end

  def test_transform_component_commits_on_success
    place_entity([10, 0, 0], [14, 4, 4])
    GEO.transform_component("id" => 4242, "position" => [381.0, 0.0, 0.0])
    assert_equal [[:start, "Transform Component"], :commit], @model.log
  end

  def test_position_moves_world_bbox_min_to_target_at_top_level
    # 381 мм = 15"; bounds.min = 10" — абсолютная семантика двигает на 5", а
    # не на все 15" (старая относительная).
    place_entity([10, 0, 0], [14, 4, 4])
    result = GEO.transform_component("id" => 4242, "position" => [381.0, 0.0, 0.0])
    assert_matrix F.translation(5, 0, 0), recorded
    assert_equal 4242, result["id"], "happy path must commit and describe the entity"
  end

  def test_position_inside_a_rotated_parent_is_conjugated
    # Local box (0,0,0)-(2,1,1) through ROTATED: world x 99..100, y 0..2, z 0..1.
    place_entity([0, 0, 0], [2, 1, 1], ROTATED)
    GEO.transform_component("id" => 4242, "position" => [0.0, 0.0, 0.0])
    assert_matrix F.multiply(F.translation(-99, 0, 0), ROTATED), F.multiply(ROTATED, recorded)
  end

  def test_position_inside_a_scaled_parent_reaches_the_world_target
    # Scaled 2× along X: local x 1..2 is world x 2..4; 254 mm = 10" on x.
    scaled = F.scaling([0, 0, 0], 2, 1, 1)
    place_entity([1, 0, 0], [2, 1, 1], scaled)
    GEO.transform_component("id" => 4242, "position" => [254.0, 0.0, 0.0])
    assert_point [10, 0, 0], F.apply(scaled, F.apply(recorded, [1, 0, 0]))
  end

  def test_rotation_turns_about_world_axes_through_the_world_center
    place_entity([0, 0, 0], [2, 1, 1], ROTATED)
    GEO.transform_component("id" => 4242, "rotation" => [0, 0, 90])
    world = F.rotation([99.5, 1.0, 0.5], 2, 90)
    assert_matrix F.multiply(world, ROTATED), F.multiply(ROTATED, recorded)
  end

  def test_scale_is_along_world_axes_about_the_world_center
    place_entity([0, 0, 0], [2, 1, 1], ROTATED)
    GEO.transform_component("id" => 4242, "scale" => [2, 1, 1])
    world = F.scaling([99.5, 1.0, 0.5], 2, 1, 1)
    assert_matrix F.multiply(world, ROTATED), F.multiply(ROTATED, recorded)
  end

  def test_open_and_closed_parent_reach_the_same_world_target
    # Closed: the parent at ROTATED, the bounds local. Open (spec §3): the
    # parent instance reports the identity and the bounds are world.
    place_entity([0, 0, 0], [2, 1, 1], ROTATED)
    GEO.transform_component("id" => 4242, "position" => [0.0, 0.0, 0.0])
    closed = recorded
    place_entity([99, 0, 0], [100, 2, 1], FrameFakes::IDENTITY)
    GEO.transform_component("id" => 4242, "position" => [0.0, 0.0, 0.0])
    open = recorded
    assert_matrix open, F.multiply(ROTATED, F.multiply(closed, F.inverse(ROTATED)))
    assert_matrix F.translation(-99, 0, 0), open
  end
end

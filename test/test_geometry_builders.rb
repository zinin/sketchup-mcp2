# test/test_geometry_builders.rb
#
# Юнит-пин build_sphere без SketchUp (T-02): фейковая Entities-коллекция
# ведёт себя как SketchUp — add_face кидает на вырожденной грани (две точки
# ближе 1e-3 дюйма). До фикса полюсные квады выбрасывались rescue-глушилкой
# и сетка оставалась открытой; фикс обязан давать полный manifold-грид
# с треугольниками на полюсных полосах.
#
# Границы фейка (осознанные): TOLERANCE=1e-3 — эвристика «SketchUp сливает
# близкие точки», НЕ документированная константа API (для segments=16
# запас многократный); реальный add_face может вернуть nil, а не бросить —
# фейк строже реального API. Тест пинит поведение БИЛДЕРА; живой пин —
# smoke шаг 20 (z-span сферы d=100). Не подгонять фикс под цифру 256.
# dims[1]/dims[2] билдер игнорирует (сфера строится по dims[0]) — тест
# НЕ подтверждает поддержку эллипсоидов.
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
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

  # segments 1-2 молча давали вырожденную геометрию — теперь -32602 сразу.
  def test_sphere_rejects_segments_below_three
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { GEO.build_sphere(FakeEntities.new, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], 2) }
    assert_equal(-32602, err.code)
  end

  # Тот же guard для cylinder/cone: segments=2 доходил до add_face с двумя
  # точками и падал непрозрачным -32603.
  def test_cylinder_rejects_segments_below_three
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { GEO.build_cylinder(FakeEntities.new, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], 2) }
    assert_equal(-32602, err.code)
  end

  def test_cone_rejects_segments_below_three
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { GEO.build_cone(FakeEntities.new, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], 2) }
    assert_equal(-32602, err.code)
  end

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

  def test_validate_min_dimensions_checks_only_consumed_indices
    # Контракт tools.py: cylinder/cone потребляют [0]=diameter и [2]=height
    # ([1] игнорируется), sphere — только [0]. Игнорируемый индекс не режем.
    assert_equal [10.0, 0.5, 10.0],
      GEO.validate_min_dimensions!([10.0, 0.5, 10.0], "cylinder")
    assert_equal [10.0, 0.5, 0.5],
      GEO.validate_min_dimensions!([10.0, 0.5, 0.5], "sphere")
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      GEO.validate_min_dimensions!([10.0, 100.0, 0.5], "cone")
    end
    assert_equal(-32602, err.code)
    assert_match(/dimensions\[2\]/, err.message)
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
end

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

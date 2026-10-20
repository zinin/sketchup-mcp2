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
#
# Ориентация граней (live, SketchUp 2026.1, 2026-10-20): конус вне земли и
# любая сфера выходили вывернутыми (нормали граней внутрь тела), а
# volume/manifold? этого не показывают. Фейк воспроизводит два наблюдённых
# правила SketchUp (см. FaceCollector), тесты проверяют итог — нормали граней
# относительно центра тела, а не последовательность вызовов билдера.
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

# Каждая константа охраняется отдельно: другой файл мог определить Sketchup, но
# не Group (в run_all так делают test_application.rb, test_model_undo.rb и
# test_settings_dialog.rb), а NamedGroup ниже наследует Sketchup::Group.
# Билдер сферы собирает грани через entities.grep(Sketchup::Face): фейковые
# грани обязаны быть её подклассом.
module Sketchup
  class Group; end unless defined?(Sketchup::Group)
  class ComponentInstance; end unless defined?(Sketchup::ComponentInstance)
  class Face; end unless defined?(Sketchup::Face)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"

class TestGeometryBuilders < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry

  # SketchUp сливает/отвергает точки ближе ~1e-3 дюйма.
  TOLERANCE = 1.0e-3
  SEGMENTS  = 16

  # Грань фейка: контур из точек [x, y, z]. Нормаль считается из порядка
  # вершин (метод Ньюэлла: против часовой стрелки — на наблюдателя), поэтому
  # reverse! разворачивает контур вместе с нормалью, как Face#reverse!.
  class FakeFace < Sketchup::Face
    Vec    = Struct.new(:x, :y, :z)
    Bounds = Struct.new(:center)

    attr_reader :points

    def initialize(points)
      @points = points.dup
    end

    def normal
      nx = ny = nz = 0.0
      @points.each_with_index do |a, i|
        b = @points[(i + 1) % @points.length]
        nx += (a[1] - b[1]) * (a[2] + b[2])
        ny += (a[2] - b[2]) * (a[0] + b[0])
        nz += (a[0] - b[0]) * (a[1] + b[1])
      end
      len = Math.sqrt(nx**2 + ny**2 + nz**2)
      Vec.new(nx / len, ny / len, nz / len)
    end

    def bounds
      Bounds.new(Vec.new(*(0..2).map { |axis| @points.map { |p| p[axis] }.minmax.sum / 2.0 }))
    end

    def reverse!
      @points.reverse!
      self
    end

    # Лежит ли вся грань в плоскости z = 0 («земля»).
    def on_ground?
      @points.all? { |p| p[2].abs < 1.0e-9 }
    end

    # Рёбра контура в порядке обхода — пары точек, округлённых до 1e-6:
    # копии южного полюса сферы совпадают лишь с точностью до 1e-16.
    def edges
      keys = @points.map { |p| p.map { |v| v.round(6) } }
      keys.each_with_index.map { |a, i| [a, keys[(i + 1) % keys.length]] }
    end
  end

  # Entities-коллекция группы. Как и SketchUp, add_face принимает точки
  # списком аргументов или одним массивом, а ориентирует грань по двум
  # наблюдённым правилам (live 2026-10-20):
  #   1. Нормаль берётся из порядка вершин, но круг на z = 0 SketchUp
  #      разворачивает вниз.
  #   2. Новая грань, делящая ребро с уже существующей, ориентируется как она,
  #      то есть обходит общее ребро в обратную сторону.
  # Граница фейка: решает первое найденное общее ребро, а соседи в билдерах
  # согласованы между собой, так что случая «соседи спорят» нет.
  class FaceCollector
    attr_reader :faces

    def initialize
      @faces = []
      @by_edge = {}
    end

    def add_face(*pts)
      pts = pts.first if pts.length == 1 && pts.first.first.is_a?(Array)
      pts.combination(2) do |a, b|
        d = Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)
        raise ArgumentError, "degenerate face: duplicate points" if d < TOLERANCE
      end
      face = FakeFace.new(pts)
      orient(face)
      face.edges.each { |a, b| (@by_edge[[a, b].sort] ||= []) << face }
      @faces << face
      face
    end

    def grep(klass)
      @faces.grep(klass)
    end

    private

    def orient(face)
      face.reverse! if face.on_ground? && face.normal.z > 0
      face.edges.each do |a, b|
        neighbour = (@by_edge[[a, b].sort] || []).first
        next unless neighbour
        face.reverse! if neighbour.edges.include?([a, b])
        break
      end
    end
  end

  # SketchUp, который ориентирует первую грань наружу (гипотетическая другая
  # версия): остальные грани следуют за ней как за соседом.
  class OutwardFirstCollector < FaceCollector
    def add_face(*pts)
      face = super
      face.reverse! if @faces.length == 1 && face.normal.z < 0
      face
    end
  end

  class FakeGroup
    attr_reader :entities
    def initialize(collector = FaceCollector.new)
      @entities = collector
    end
  end

  # collector_class — Entities-коллекция, которую получит группа.
  class FakeEntities
    attr_reader :group
    def initialize(collector_class = FaceCollector)
      @collector_class = collector_class
    end
    def add_group
      @group = FakeGroup.new(@collector_class.new)
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
  # Контуры граней (точки по порядку вершин), без нормалей.
  def build_faces
    entities = FakeEntities.new
    GEO.build_sphere(entities, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], SEGMENTS)
    entities.group.entities.faces.map(&:points)
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

  # ---------- ориентация: тела строятся наружу ----------

  # Грань смотрит наружу, если её нормаль направлена от внутренней точки тела
  # к центру грани (среднему её вершин); у выпуклого тела внутренняя точка —
  # любая. Внутренние точки ниже заданы по параметрам построения, не по
  # результату билдера.
  def outward?(face, inside)
    n = face.normal
    c = face.points.transpose.map { |axis| axis.sum / axis.length }
    n.x * (c[0] - inside[0]) + n.y * (c[1] - inside[1]) + n.z * (c[2] - inside[2]) > 0
  end

  def assert_all_outward(faces, inside, what)
    inward = faces.reject { |face| outward?(face, inside) }
    assert_equal 0, inward.length, "#{what}: #{inward.length} of #{faces.length} faces point inward"
  end

  # Конус диаметром 4" и высотой 3" с основанием на высоте z: ось в (2, 2),
  # внутренняя точка — на оси на середине высоты. Основание — единственная
  # грань с SEGMENTS вершинами, остальные — боковые треугольники.
  def assert_cone_outward(z)
    entities = FakeEntities.new
    GEO.build_cone(entities, [0.0, 0.0, z], [4.0, 4.0, 3.0], SEGMENTS)
    faces = entities.group.entities.faces
    assert_equal SEGMENTS + 1, faces.length, "the base and one triangle per segment"
    base = faces.find { |face| face.points.length == SEGMENTS }
    assert_in_delta(-1.0, base.normal.z, 1.0e-9, "the base at z=#{z} must point down, out of the cone")
    assert_all_outward(faces, [2.0, 2.0, z + 1.5], "cone at z=#{z}")
  end

  # На земле SketchUp сам разворачивает основание вниз: билдер не должен
  # развернуть его обратно вверх.
  def test_cone_on_the_ground_plane_is_outward
    assert_cone_outward(0.0)
  end

  # Выше земли основание берёт нормаль по порядку вершин (вверх, внутрь
  # конуса), и боковые грани повторяли бы его: конус выходил вывернутым.
  def test_cone_above_the_ground_plane_is_outward
    assert_cone_outward(50.0)
  end

  # SketchUp ориентирует всю сферу по первой грани, а та берёт нормаль по
  # порядку вершин — внутрь, на любой высоте.
  def test_sphere_is_outward
    [[0.0, 0.0, 0.0], [10.0, -5.0, 50.0]].each do |pos|
      entities = FakeEntities.new
      GEO.build_sphere(entities, pos, [4.0, 4.0, 4.0], SEGMENTS)
      faces = entities.group.entities.faces
      assert_equal SEGMENTS * SEGMENTS, faces.length
      assert_all_outward(faces, pos.map { |v| v + 2.0 }, "sphere at #{pos.inspect}")
    end
  end

  # Если SketchUp строит сферу сразу наружу, оболочку разворачивать нельзя:
  # решение принимается по результату, а не вслепую.
  def test_sphere_that_comes_out_outward_is_left_alone
    entities = FakeEntities.new(OutwardFirstCollector)
    GEO.build_sphere(entities, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], SEGMENTS)
    assert_all_outward(entities.group.entities.faces, [2.0, 2.0, 2.0], "sphere built outward by SketchUp")
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

  # describe_entity различает group/component по классу и зовёт typename
  # только для остальных сущностей: фейк обязан быть Sketchup::Group, как
  # настоящий add_group.
  class NamedGroup < Sketchup::Group
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
    attr_reader :active_entities, :log
    def initialize
      @active_entities = NamedEntities.new
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

  def test_create_component_commits_on_success
    model, _result = create_sphere
    assert_equal [[:start, "Create Component (Sphere)"], :commit], model.log
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

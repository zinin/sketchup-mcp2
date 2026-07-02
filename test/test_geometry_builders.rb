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

  # segments 1-2 молча давали вырожденную геометрию — теперь -32602 сразу.
  def test_sphere_rejects_segments_below_three
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { GEO.build_sphere(FakeEntities.new, [0.0, 0.0, 0.0], [4.0, 4.0, 4.0], 2) }
    assert_equal(-32602, err.code)
  end
end

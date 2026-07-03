# test/test_model_empty_bbox.rb
# T-55: пустой Geom::BoundingBox SketchUp (инвертированный сентинел
# min = +1e30", max = −1e30") обязан отдавать bbox null, а не ±2.54e31 мм.
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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"

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

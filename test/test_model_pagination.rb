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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
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
end

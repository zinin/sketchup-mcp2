# test/test_geometry_guards.rb
# M-04: delete_component and transform_component act on groups and component
# instances only.
#
# Both tools were documented as "group or component" but took any entity id.
# An id from get_selection can name a raw face or edge: delete_component
# erased it, and transform_component on a face failed with a generic -32603
# "undefined method 'transform!'". Both handlers now call
# Entities.require_group_or_component! right after find!, inside the
# operation, so the refusal is -32602, nothing is touched and the operation
# is aborted.
#
# Fakes: a recording model. Its log holds [:start, label], :commit and
# :abort, so one list shows what happened and in which order. Entities are
# duck-typed; a group and a component instance subclass the guarded
# Sketchup::Group / ComponentInstance stubs because the guard checks is_a?
# (other files define their own stubs, and under run_all every file loads
# before any test runs). Entities.active_model! is stubbed per test, and
# Geom::Transformation.translation in the transform test; teardown restores
# both.
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
end

# Guarded minimum for a standalone run; under run_all other files define
# richer versions, which these guards leave alone.
module Geom
  unless defined?(Point3d)
    class Point3d
      attr_reader :x, :y, :z

      def initialize(x = 0, y = 0, z = 0)
        @x, @y, @z = x, y, z
      end
    end
  end

  class Transformation; end unless defined?(Transformation)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"

class TestGeometryGuards < Minitest::Test
  GEO = MCPforSketchUp::Handlers::Geometry
  EH  = MCPforSketchUp::Helpers::Entities
  StructuredError = MCPforSketchUp::Core::StructuredError

  # Every entity reports the same bounds, in inches.
  FakePt     = Struct.new(:x, :y, :z)
  FakeBounds = Struct.new(:min, :max)
  BOUNDS = FakeBounds.new(FakePt.new(0.0, 0.0, 0.0), FakePt.new(1.0, 2.0, 4.0))

  # What the stubbed Geom::Transformation.translation returns.
  Translation = Struct.new(:x, :y, :z)

  class RecordingModel
    attr_reader :log

    def initialize
      @log = []
      @by_id = {}
    end

    def register(entity)
      @by_id[entity.entityID] = entity
      entity
    end

    def start_operation(name, _disable_ui = true)
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

    def find_entity_by_id(id)
      @by_id[id]
    end
  end

  # What every fake entity answers. erase! and transform! record the call, so
  # a test sees an entity that was touched even when nothing else fails.
  module FakeEntity
    attr_reader :entityID, :transforms

    def initialize(id)
      @entityID = id
      @erased = false
      @transforms = []
    end

    def valid?
      true
    end

    def bounds
      BOUNDS
    end

    def erase!
      @erased = true
    end

    def erased?
      @erased
    end

    def transform!(transformation)
      @transforms << transformation
      self
    end
  end

  # A raw face, as get_selection hands out its id: not a Group or a
  # ComponentInstance. SketchUp's face has no #transform!; this one records
  # the call so that a missing guard shows up as a move, not as a NoMethodError.
  class FakeFace
    include FakeEntity

    def typename
      "Face"
    end
  end

  class FakeGroup < Sketchup::Group
    include FakeEntity
  end

  class FakeInstance < Sketchup::ComponentInstance
    include FakeEntity
  end

  def setup
    @model = RecordingModel.new
    model = @model  # a stub body runs with self == the stubbed module
    @stubs = []
    stub_singleton(EH, :active_model!) { model }
  end

  def teardown
    @stubs.reverse_each do |mod, name, original|
      mod.singleton_class.send(:remove_method, name)
      mod.define_singleton_method(name, original) if original
    end
  end

  # Replaces mod.name for one test. The original Method goes back in
  # teardown; a method that did not exist is removed again. Removing before
  # redefining keeps `ruby -w` free of "method redefined" warnings.
  def stub_singleton(mod, name, &body)
    original = mod.respond_to?(name) ? mod.method(name) : nil
    mod.singleton_class.send(:remove_method, name) if original
    @stubs << [mod, name, original]
    mod.define_singleton_method(name, &body)
  end

  # ---------- delete_component ----------

  def test_delete_rejects_a_face
    face = @model.register(FakeFace.new(11))

    err = assert_raises(StructuredError) { GEO.delete_component("id" => "11") }

    assert_equal(-32602, err.code)
    assert_equal "entity must be a Group or ComponentInstance, got #{face.class.name}", err.message
    refute face.erased?, "the face must not be erased"
    assert_equal [[:start, "Delete Component"], :abort], @model.log
  end

  def test_delete_erases_a_group
    group = @model.register(FakeGroup.new(20))

    res = GEO.delete_component("id" => "20")

    assert_equal({ "ok" => true }, res)
    assert group.erased?, "the group must be erased"
    assert_equal [[:start, "Delete Component"], :commit], @model.log
  end

  def test_delete_erases_a_component_instance
    instance = @model.register(FakeInstance.new(21))

    res = GEO.delete_component("id" => "21")

    assert_equal({ "ok" => true }, res)
    assert instance.erased?, "the instance must be erased"
    assert_equal [[:start, "Delete Component"], :commit], @model.log
  end

  # ---------- transform_component ----------

  def test_transform_rejects_a_face
    # Only an unguarded handler gets as far as building a translation; with
    # this stub that shows up as a recorded transform!.
    stub_singleton(Geom::Transformation, :translation) do |point|
      Translation.new(point.x, point.y, point.z)
    end
    face = @model.register(FakeFace.new(11))

    err = assert_raises(StructuredError) do
      GEO.transform_component("id" => "11", "position" => [100.0, 0.0, 0.0])
    end

    assert_equal(-32602, err.code)
    assert_equal "entity must be a Group or ComponentInstance, got #{face.class.name}", err.message
    assert_empty face.transforms, "nothing may be moved"
    assert_equal [[:start, "Transform Component"], :abort], @model.log
  end
end

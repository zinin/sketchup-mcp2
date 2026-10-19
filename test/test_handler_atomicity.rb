# test/test_handler_atomicity.rb
# M-08: every mutating handler rolls back when it fails mid-operation.
#
# The eleven mutating handlers wrap their edits in model.start_operation ...
# model.commit_operation and answer any StandardError with
# Geometry.safe_abort(model) and a re-raise, so one call is one undo step and
# a call that fails leaves the model as it was. ROWS holds all eleven, so a
# handler that stops aborting fails here whatever its own tests cover.
#
# A row names the handler, a call that passes validation, the model call that
# then raises RuntimeError("injected") (a path from the model: %i[layers add]
# is model.layers.add) and the operation label. Each row is a test: the
# injected error reaches the caller and the log is exactly
# [[:start, label], :abort], with no :commit. The handlers in COMMITTING run
# to the end over these fakes, so their rows also run without the failure:
# the same call commits, [[:start, label], :commit].
#
# Fakes: a recording model. Its log holds [:start, label], :commit and :abort
# and nothing else. Entity 1 is a group of two faces; they subclass the
# guarded Sketchup::Group / Face stubs because the handlers check is_a? and
# grep (other files define their own stubs, and under run_all every file
# loads before any test runs). The guarded ComponentInstance stub is not
# subclassed: the handlers name it, and a file that guards the whole
# Sketchup module expects it beside Group. The model already has a "red"
# material, so set_material creates none. Entities.active_model! is stubbed
# per test and restored in teardown. A failure is injected into the test's
# own fakes, so nothing else needs restoring.
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
  class Face; end unless defined?(Face)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/materials"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestHandlerAtomicity < Minitest::Test
  H  = MCPforSketchUp::Handlers
  EH = MCPforSketchUp::Helpers::Entities

  # Entity 1 reports these bounds, in inches.
  FakePt     = Struct.new(:x, :y, :z)
  FakeBounds = Struct.new(:min, :max)
  BOUNDS = FakeBounds.new(FakePt.new(0.0, 0.0, 0.0), FakePt.new(1.0, 2.0, 4.0))

  FakeMaterial = Struct.new(:name)

  FakeLayer = Struct.new(:entityID, :name) do
    def visible?
      true
    end
  end

  # model.layers: add makes the layer create_layer reports.
  class FakeLayers
    def add(name)
      FakeLayer.new(3, name)
    end
  end

  # set_material paints a group through the faces among its entities.
  class FakeFace < Sketchup::Face
    attr_accessor :material
  end

  # Entity 1: delete_component erases it, set_material paints its faces. It
  # answers what find!, the group guard, set_material and describe_entity
  # read.
  class FakeGroup < Sketchup::Group
    attr_reader :entityID, :name, :entities

    def initialize(id, entities)
      @entityID = id
      @name = "board"
      @entities = entities
    end

    def valid?
      true
    end

    def bounds
      BOUNDS
    end

    def erase!
      true
    end
  end

  # Logs [:start, label], :commit and :abort, and nothing else.
  # find_entity_by_id resolves registered entities, layers.add makes a layer
  # and materials already holds "red". active_entities is where
  # create_component builds; its first call there, add_group, is that row's
  # failure, so the object needs no methods of its own.
  class RecordingModel
    attr_reader :log, :active_entities, :layers, :materials

    def initialize
      @log = []
      @by_id = {}
      @active_entities = Object.new
      @layers = FakeLayers.new
      @materials = { "red" => FakeMaterial.new("red") }
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

  def setup
    @model = RecordingModel.new
    @model.register(FakeGroup.new(1, [FakeFace.new, FakeFace.new]))
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

  # Makes the last call of `path` raise RuntimeError("injected") on the
  # object the calls before it reach from the model. Returns that error.
  def inject_failure(path)
    *readers, call = path
    receiver = readers.reduce(@model) { |object, reader| object.public_send(reader) }
    error = RuntimeError.new("injected")
    receiver.define_singleton_method(call) { |*| raise error }
    error
  end

  # handler module, method, params, the model call that raises, label
  ROWS = [
    [H::Geometry, :create_component, { "type" => "cube", "dimensions" => [10, 10, 10] },
     %i[active_entities add_group], "Create Component (Cube)"],
    [H::Geometry, :delete_component, { "id" => "1" },
     %i[find_entity_by_id], "Delete Component"],
    [H::Geometry, :transform_component, { "id" => "1", "position" => [0, 0, 0] },
     %i[find_entity_by_id], "Transform Component"],
    [H::Materials, :set_material, { "id" => "1", "material" => "red" },
     %i[find_entity_by_id], "Set Material (Red)"],
    [H::Operations, :boolean_operation, { "target_id" => "1", "tool_id" => "2", "operation" => "union" },
     %i[find_entity_by_id], "Boolean Union"],
    [H::Operations, :chamfer_edges, { "entity_id" => "1", "distance" => 2 },
     %i[find_entity_by_id], "Chamfer Edges"],
    [H::Operations, :fillet_edges, { "entity_id" => "1", "radius" => 2 },
     %i[find_entity_by_id], "Fillet Edges"],
    [H::Model, :create_layer, { "name" => "L" },
     %i[layers add], "Create Layer (L)"],
    [H::Joints, :create_mortise_tenon, { "mortise_id" => "1", "tenon_id" => "2" },
     %i[find_entity_by_id], "Mortise and Tenon"],
    [H::Joints, :create_dovetail, { "tail_id" => "1", "pin_id" => "2" },
     %i[find_entity_by_id], "Dovetail Joint"],
    [H::Joints, :create_finger_joint, { "board1_id" => "1", "board2_id" => "2" },
     %i[find_entity_by_id], "Finger Joint"],
  ].freeze

  # The handlers whose row call runs to the end over these fakes.
  COMMITTING = %i[delete_component set_material create_layer].freeze

  ROWS.each do |handler, name, params, failing_call, label|
    define_method("test_#{name}_rolls_back_on_failure") do
      injected = inject_failure(failing_call)
      err = assert_raises(RuntimeError) { handler.public_send(name, params) }
      assert_same injected, err
      assert_equal [[:start, label], :abort], @model.log
    end

    next unless COMMITTING.include?(name)

    define_method("test_#{name}_commits_on_success") do
      handler.public_send(name, params)
      assert_equal [[:start, label], :commit], @model.log
    end
  end
end

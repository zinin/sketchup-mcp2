# test/test_handler_atomicity.rb
# M-08: every mutating handler rolls back when it fails mid-operation.
#
# The eleven mutating handlers wrap their edits in model.start_operation ...
# model.commit_operation and answer any StandardError with
# Geometry.safe_abort(model) and a re-raise, so one call is one undo step and
# a call that fails leaves the model as it was. ROWS holds all eleven, so a
# handler that stops aborting fails here whatever its own tests cover. The
# last tests read the handler files and find every method that calls
# start_operation, so a new site without a row fails too, and pin that scan.
# They also keep operation handlers and eval_ruby out of READ_ONLY_TOOLS.
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
# per test and restored by SingletonStubs. A failure is injected into the
# test's own fakes, so nothing else needs restoring.
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "support/dispatch_table"

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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"

class TestHandlerAtomicity < Minitest::Test
  include SingletonStubs

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
    stub_singleton(EH, :active_model!) { model }
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
  # Success-to-commit checks elsewhere: chamfer_edges/fillet_edges in
  # test/test_edge_ops.rb; create_component in test/test_geometry_builders.rb;
  # transform_component in test/test_transform_absolute.rb; boolean_operation
  # in test/test_boolean_direction.rb. The joinery handlers have none until
  # joinery is rewritten (part 3).
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

  # ---------- every start_operation site has a row ----------
  #
  # The scan reads the handler files as text. It sees `start_operation(...)`
  # and `start_operation "..."`, in a `def self.x` or a plain `def x`, and it
  # links a helper such as run_edge_op to the methods that call it with
  # parentheses. Three patterns slip past it silently:
  #   * an operation started through send or define_method;
  #   * a `def` that does not start its line (`private def x`): its code is
  #     counted for the method before it, so it is missed when that method
  #     has a row;
  #   * a new handler that calls a helper without parentheses
  #     (`run_edge_op p`) while the other callers use them.
  # A paren-less call fails loudly in two other cases: every caller of the
  # helper is paren-less (the helper is listed without a row), or a handler
  # that has a row switches to one (its row names a handler the scan no
  # longer finds). None of the silent patterns is in handlers/ today.

  HANDLER_DIR = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/handlers", __dir__)

  # { "Module" => text } of the handler files.
  def handler_sources
    Dir[File.join(HANDLER_DIR, "*.rb")].sort.to_h do |path|
      [File.basename(path, ".rb").capitalize, File.read(path, encoding: "UTF-8")]
    end
  end

  # { "method" => code } for the methods in `source`. Every `def`, with or
  # without self., starts a method that runs to the next def, so a def added
  # after a row method does not join its code. The code leaves out the comment
  # lines: a comment that names start_operation does not count.
  def methods_of(source)
    chunks = source.split(/^(?=[ \t]*def\b)/)
    chunks.filter_map do |chunk|
      name = chunk[/\A[ \t]*def[ \t]+(?:self\.)?(\w+[?!=]?)/, 1]
      [name, chunk.lines.grep_v(/\A\s*#/).join] if name
    end.to_h
  end

  # The method itself, or the methods that call it, and theirs in turn: a
  # method that starts an operation for others (run_edge_op, for chamfer_edges
  # and fillet_edges) is not what a client calls.
  def entry_points(methods, name, seen = [])
    return [] if seen.include?(name)

    callers = methods.select { |other, code| other != name && code.match?(/\b#{Regexp.escape(name)}\(/) }.keys
    return [name] if callers.empty?

    callers.flat_map { |outer| entry_points(methods, outer, seen + [name]) }
  end

  # "Module.method" of every method in `sources` ({ "Module" => text }) that
  # starts an operation.
  def operation_handlers(sources = handler_sources)
    sources.flat_map do |module_name, source|
      methods = methods_of(source)
      openers = methods.select { |_, code| code.match?(/\bstart_operation[\s(]/) }.keys
      openers.flat_map { |name| entry_points(methods, name) }.uniq
             .map { |name| "#{module_name}.#{name}" }
    end
  end

  def test_every_handler_that_starts_an_operation_has_a_row
    rows = ROWS.map { |handler, name, *| "#{handler.name.split('::').last}.#{name}" }
    found = operation_handlers

    assert_empty found - rows,
      "these handlers call start_operation but have no row in ROWS: add one"
    assert_empty rows - found,
      "these rows name handlers that no longer call start_operation (or the scan misses them)"
  end

  # A stale-socket retry must never repeat a model edit or arbitrary Ruby.
  def test_read_only_tools_do_not_route_to_mutating_handlers
    routes = DispatchTable.routes.flat_map do |names, mod, meth|
      names.map { |name| [name, "#{mod}.#{meth}"] }
    end.to_h
    mutating = operation_handlers + ["Eval.eval_ruby"]

    H::Dispatch::READ_ONLY_TOOLS.each do |name|
      assert routes.key?(name), "#{name} is read-only but has no dispatch route"
      refute_includes mutating, routes[name], "#{name} is read-only but routes to #{routes[name]}"
    end
  end

  def test_the_scan_handles_bare_calls_plain_defs_helpers_and_comments
    source = <<~RUBY
      module Fake
        def self.quiet(params)
          # model.start_operation("only in a comment", true)
          nil
        end

        # The next one calls model.start_operation("for real", true) and says so.
        def self.plain(params)
          model.start_operation("Plain", true)
        end

        def self.bare(params)
          model.start_operation "Bare", true
        end

        def self.helper(params)
          model.start_operation("Helper", true)
        end

        def self.uses_helper(params)
          helper(params)
        end

        def self.also_uses_helper(params)
          helper(params)
        end

        def instance_method(params)
          model.start_operation("Instance", true)
        end
      end
    RUBY

    assert_equal %w[Fake.also_uses_helper Fake.bare Fake.instance_method Fake.plain Fake.uses_helper],
                 operation_handlers("Fake" => source).sort
  end
end

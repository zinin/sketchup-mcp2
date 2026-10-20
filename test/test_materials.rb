# test/test_materials.rb
# M-04: set_material on faces and edges, and how a material spec resolves.
#
# Measured in SketchUp 2026.1: set_material on a face id painted the face and
# committed, then describe_entity read Face#name (there is none) and the call
# failed with "[-32603] undefined method 'name' for Sketchup::Face" although
# the paint was already in the model. The description is now built before
# commit_operation, so a failure there rolls the paint back, and a face or an
# edge describes itself by its typename with a null name.
#
# A material spec resolves in this order: a material of the model with that
# name, matched without regard to case as SketchUp's Materials#[] does (an
# existing "Red" is used for "red"); a named color or "#rrggbb" in any case,
# found or created under its lower-case name; anything else is -32602, before
# a material is created.
#
# Fakes: a recording model. Its log holds [:start, label], :commit and :abort,
# [:add, name] for a material created and :bounds each time an entity is
# described, so one list shows what happened and in which order. Entities are
# duck-typed. Sketchup::Group / ComponentInstance / Face / Edge / Color are
# guarded stubs: other files define their own, and under run_all every file
# loads before any test runs. Color keeps the shape test_pure_helpers.rb reads
# (#rgb), because whichever file loads first wins the guard.
# Entities.active_model! is stubbed per test and restored in teardown.
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
  class Face; end unless defined?(Face)
  class Edge; end unless defined?(Edge)

  unless const_defined?(:Color)
    class Color
      attr_reader :rgb

      def initialize(*rgb)
        @rgb = rgb
      end
    end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/materials"

class TestMaterials < Minitest::Test
  M  = MCPforSketchUp::Handlers::Materials
  G  = MCPforSketchUp::Handlers::Geometry
  EH = MCPforSketchUp::Helpers::Entities
  StructuredError = MCPforSketchUp::Core::StructuredError

  # Every entity reports the same bounds, in inches.
  FakePt     = Struct.new(:x, :y, :z)
  FakeBounds = Struct.new(:min, :max)
  BOUNDS  = FakeBounds.new(FakePt.new(0.0, 0.0, 0.0), FakePt.new(1.0, 2.0, 4.0))
  BBOX_MM = { "min" => [0.0, 0.0, 0.0], "max" => [25.4, 50.8, 101.6] }.freeze

  class FakeMaterial
    attr_reader :name
    attr_accessor :color

    def initialize(name)
      @name = name
    end
  end

  # model.materials: [] matches names without regard to case, like
  # SketchUp's Materials#[], and answers nil for a name it does not have;
  # add logs.
  class FakeMaterials
    def initialize(log)
      @log = log
      @by_name = {}
    end

    # A material the model already had; not logged.
    def seed(name)
      @by_name[name] = FakeMaterial.new(name)
    end

    def [](name)
      @by_name.values.find { |material| material.name.casecmp?(name) }
    end

    def add(name)
      @log << [:add, name]
      seed(name)
    end
  end

  class RecordingModel
    attr_reader :log, :materials

    def initialize
      @log = []
      @materials = FakeMaterials.new(@log)
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

  # What every fake entity answers. #bounds is what describe_entity reads
  # first; logging it shows whether it ran before commit_operation.
  module FakeEntity
    attr_reader :entityID

    def initialize(model, id)
      @model = model
      @entityID = id
    end

    def valid?
      true
    end

    def bounds
      @model.log << :bounds
      BOUNDS
    end
  end

  # Faces and edges have no #name, like SketchUp's.
  class FakeFace < Sketchup::Face
    include FakeEntity
    attr_accessor :material

    def typename
      "Face"
    end
  end

  class FakeEdge < Sketchup::Edge
    include FakeEntity
    attr_accessor :material

    def typename
      "Edge"
    end
  end

  # Not a Sketchup::Group / ComponentInstance / Face / Edge: nothing to paint.
  class FakeDefinition
    include FakeEntity
    attr_reader :entities

    def initialize(model, id, entities = [])
      super(model, id)
      @entities = entities
    end

    def typename
      "ComponentDefinition"
    end
  end

  class FakeGroup < Sketchup::Group
    include FakeEntity
    attr_reader :name, :entities, :make_unique_calls

    def initialize(model, id, name, entities)
      super(model, id)
      @name = name
      @entities = entities
      @make_unique_calls = 0
    end

    def make_unique
      @make_unique_calls += 1
      self
    end
  end

  # Its faces live in the definition.
  class FakeInstance < Sketchup::ComponentInstance
    include FakeEntity
    attr_reader :name, :definition, :make_unique_calls

    def initialize(model, id, name, definition)
      super(model, id)
      @name = name
      @definition = definition
      @make_unique_calls = 0
    end

    def make_unique
      @make_unique_calls += 1
      self
    end
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

  def paint(entity, spec)
    M.set_material("id" => entity.entityID.to_s, "material" => spec)
  end

  def face(id)
    @model.register(FakeFace.new(@model, id))
  end

  # ---------- resolving a material spec ----------

  def test_canonical_material_name
    assert_equal "red",     M.canonical_material_name("Red")
    assert_equal "grey",    M.canonical_material_name("GREY")
    assert_equal "#a05030", M.canonical_material_name("#A05030")
    assert_nil M.canonical_material_name("oak")
    assert_nil M.canonical_material_name("#abc")
  end

  def test_canonical_material_name_rejects_what_is_not_a_color
    ["#a0503", "#a050300", "a05030", "#12345g", " red", "red ", "#a05030\n"].each do |spec|
      assert_nil M.canonical_material_name(spec), "#{spec.inspect} is not a color"
    end
  end

  def test_existing_exact_material_wins
    oak = @model.materials.seed("Oak")
    target = face(11)
    paint(target, "Oak")
    assert_same oak, target.material
    assert_equal [[:start, "Set Material (Oak)"], :bounds, :commit], @model.log, "nothing added"
  end

  def test_existing_exact_material_wins_over_a_named_color
    # The model's own "Red" is used as is: not recolored, no "red" beside it.
    red = @model.materials.seed("Red")
    target = face(11)
    paint(target, "Red")
    assert_same red, target.material
    assert_nil red.color
    assert_equal [[:start, "Set Material (Red)"], :bounds, :commit], @model.log, "nothing added"
  end

  def test_existing_material_is_found_whatever_the_case
    # SketchUp's Materials#[] ignores case: "red" finds the model's "Red",
    # which is used as is — not recolored, no "red" added beside it.
    red = @model.materials.seed("Red")
    target = face(11)
    paint(target, "red")
    assert_same red, target.material
    assert_nil red.color
    assert_equal [[:start, "Set Material (Red)"], :bounds, :commit], @model.log, "nothing added"
  end

  def test_named_color_is_case_insensitive_and_reuses_one_material
    first = face(11)
    second = face(12)
    paint(first, "Red")
    paint(second, "red")
    assert_same first.material, second.material
    assert_equal "red", first.material.name
    assert_equal [255, 0, 0], first.material.color.rgb
    assert_equal [[:start, "Set Material (Red)"], [:add, "red"], :bounds, :commit,
                  [:start, "Set Material (Red)"], :bounds, :commit], @model.log
  end

  def test_hex_color_is_stored_under_its_lower_case_name
    first = face(11)
    second = face(12)
    paint(first, "#A05030")
    paint(second, "#a05030")
    assert_same first.material, second.material
    assert_equal "#a05030", first.material.name
    assert_equal [160, 80, 48], first.material.color.rgb
    assert_equal [[:start, "Set Material (#a05030)"], [:add, "#a05030"], :bounds, :commit,
                  [:start, "Set Material (#a05030)"], :bounds, :commit], @model.log
  end

  def test_invalid_color_aborts
    target = face(11)
    err = assert_raises(StructuredError) { paint(target, "garbage") }
    assert_equal(-32602, err.code)
    assert_equal "invalid color: \"garbage\" " \
                 "(expected an existing material name, a named color or '#rrggbb')", err.message
    assert_equal [[:start, "Set Material (Garbage)"], :abort], @model.log, "nothing added"
    assert_nil target.material
  end

  # ---------- what can be painted ----------

  def test_set_material_on_face_reports_face_and_describes_before_commit
    target = face(11)
    refute_respond_to target, :name, "the fake must lack #name, like Sketchup::Face"

    res = paint(target, "red")

    assert_equal({ "id" => 11, "name" => nil, "type" => "face", "bbox_mm" => BBOX_MM }, res)
    assert_equal [[:start, "Set Material (Red)"], [:add, "red"], :bounds, :commit], @model.log,
                 "the description (bounds) must be built before commit_operation"
    assert_equal "red", target.material.name
  end

  def test_set_material_on_edge_reports_edge
    target = @model.register(FakeEdge.new(@model, 12))
    res = paint(target, "blue")
    assert_equal({ "id" => 12, "name" => nil, "type" => "edge", "bbox_mm" => BBOX_MM }, res)
    assert_equal "blue", target.material.name
    assert_equal :commit, @model.log.last
  end

  def test_failing_description_rolls_the_paint_back
    target = face(11)
    target.define_singleton_method(:bounds) { raise "injected" }
    err = assert_raises(RuntimeError) { paint(target, "red") }
    assert_equal "injected", err.message
    assert_equal [[:start, "Set Material (Red)"], [:add, "red"], :abort], @model.log
  end

  def test_non_paintable_entity_is_rejected
    definition = @model.register(FakeDefinition.new(@model, 7))
    err = assert_raises(StructuredError) { paint(definition, "red") }
    assert_equal(-32602, err.code)
    assert_equal "set_material needs a group, component instance, face or edge; " \
                 "entity 7 is a ComponentDefinition", err.message
    assert_equal [[:start, "Set Material (Red)"], :abort], @model.log, "nothing added"
  end

  def test_group_is_painted_through_its_direct_child_faces
    faces = [FakeFace.new(@model, 31), FakeFace.new(@model, 32)]
    edge = FakeEdge.new(@model, 33)
    group = @model.register(FakeGroup.new(@model, 20, "frame", faces + [edge]))

    res = paint(group, "red")

    assert_equal({ "id" => 20, "name" => "frame", "type" => "group", "bbox_mm" => BBOX_MM }, res)
    assert_equal 1, group.make_unique_calls, "only this instance is painted"
    assert_equal %w[red red], faces.map { |f| f.material.name }
    assert_nil edge.material
    assert_equal [[:start, "Set Material (Red)"], [:add, "red"], :bounds, :commit], @model.log
  end

  def test_component_instance_is_painted_through_its_definition_faces
    faces = [FakeFace.new(@model, 41), FakeFace.new(@model, 42)]
    instance = @model.register(
      FakeInstance.new(@model, 21, "chair", FakeDefinition.new(@model, 91, faces)))

    res = paint(instance, "red")

    assert_equal({ "id" => 21, "name" => "chair", "type" => "component", "bbox_mm" => BBOX_MM }, res)
    assert_equal 1, instance.make_unique_calls, "only this instance is painted"
    assert_equal %w[red red], faces.map { |f| f.material.name }
    assert_equal :commit, @model.log.last
  end

  # ---------- describe_entity ----------

  def test_describe_entity_keeps_group_and_component_shape
    group = FakeGroup.new(@model, 20, "frame", [])
    instance = FakeInstance.new(@model, 21, "chair", FakeDefinition.new(@model, 91))
    assert_equal({ "id" => 20, "name" => "frame", "type" => "group", "bbox_mm" => BBOX_MM },
                 G.describe_entity(group))
    assert_equal({ "id" => 21, "name" => "chair", "type" => "component", "bbox_mm" => BBOX_MM },
                 G.describe_entity(instance))
  end

  def test_describe_entity_names_faces_and_edges_by_typename
    assert_equal({ "id" => 11, "name" => nil, "type" => "face", "bbox_mm" => BBOX_MM },
                 G.describe_entity(FakeFace.new(@model, 11)))
    assert_equal({ "id" => 12, "name" => nil, "type" => "edge", "bbox_mm" => BBOX_MM },
                 G.describe_entity(FakeEdge.new(@model, 12)))
  end
end

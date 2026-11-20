# test/test_mortise_tenon.rb
# create_mortise_tenon over fakes (M-02). The joint sits on the contact area
# of two boards that touch face to face; a cutter subtracted from the mortise
# board and a piece united with the tenon board build it inside one
# operation, which commits only when both results are solids, the mortise
# board lost exactly the part of the joint inside it (all of it unless the
# mortise runs through), the tenon board gained the whole joint, the mortise
# board is one piece and the tenon is one shell with its board. Anything
# else aborts: the log is [[:start, label], :abort] and no half-built joint
# is committed.
#
# The boards are the probe of the design's §3: a leg 50 x 50 x 300 mm with a
# rail 200 x 20 x 80 mm against its +X face, centred on it. The joint is 10
# wide, 40 high and 20 deep (8 000 mm³).
#
# Block A (§6.6a): the boxes are WORLD boxes — each board's definition
# bounds through the matrix of its parents and its own transformation
# (Frames) — so the joint follows the model's X, Y and Z in every edit
# state, a board must be aligned with the model's axes, and the cutter and
# the tenon piece, built at world coordinates beside the boards, are taken
# into the parent's frame (transform! by the parent's inverse). Volumes are
# in the parent's frame: the expected ones are divided by the parent's
# volume scale. A pocket that frees less than its box gets its own advice.
#
# Fakes: a recording model whose log holds [:start, label], :commit and :abort
# and nothing else, and which finds the boards by id (nothing is open for
# editing unless a test sets active_path); a parent whose entities are a
# sentinel (the model: the walk stops at it), or a FrameFakes::Definition
# placed at a matrix (a group around the boards); boards that subclass the
# guarded Sketchup::Group or Sketchup::ComponentInstance (the handler checks
# is_a?), whose transformation is a matrix and whose definition's bounds are
# their bounds taken back through it (as SketchUp's are for an axis-aligned
# board); results whose faces answer all_connected. make_box is stubbed: it
# records its arguments and returns the cutter, then the tenon piece, whose
# subtract / union record their operand and return the configured result (or
# nil), and whose transform! records the matrix Frames.transformation was
# given (stubbed). Lengths are written in mm and converted with mm / mm3.
# Under run_all every test file loads before any test runs and some reopen
# the Sketchup stubs, so the fakes define every method the handler calls on
# them.
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "support/frame_fakes"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
  class Face; end unless defined?(Face)
  class ComponentDefinition; end unless defined?(ComponentDefinition)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestMortiseTenon < Minitest::Test
  include SingletonStubs

  J  = MCPforSketchUp::Handlers::Joints
  F  = MCPforSketchUp::Helpers::Frames
  EH = MCPforSketchUp::Helpers::Entities
  HG = MCPforSketchUp::Helpers::Geometry
  StructuredError = MCPforSketchUp::Core::StructuredError

  LABEL = "Mortise and Tenon"

  FakePoint  = Struct.new(:x, :y, :z)
  FakeBounds = Struct.new(:min, :max)
  # A board's definition: what the handler reads from it.
  BoardDefinition = Struct.new(:name, :bounds)
  # What the stubbed Frames.transformation returns: the matrix it was given.
  Marker = Struct.new(:matrix)

  # A transformation: to_a gives its 16 numbers, column-major like
  # Geom::Transformation#to_a — the three axes, then the origin.
  def self.axes(x, y, z, origin = [0, 0, 0])
    FrameFakes::Transform.new([*x, 0, *y, 0, *z, 0, *origin, 1].map(&:to_f))
  end

  C45 = Math.sqrt(0.5)
  C30 = Math.sqrt(3) / 2
  UNROTATED  = axes([1, 0, 0], [0, 1, 0], [0, 0, 1])
  ROTATED_90 = axes([0, 1, 0], [-1, 0, 0], [0, 0, 1])
  ROTATED_45 = axes([C45, C45, 0], [-C45, C45, 0], [0, 0, 1])
  ROTATED_30 = axes([C30, 0.5, 0], [-0.5, C30, 0], [0, 0, 1])
  MOVED      = axes([1, 0, 0], [0, 1, 0], [0, 0, 1], [1000 / 25.4, 0, 0])  # 1000 mm along X

  # The boards' parent (the model, or a group's definition). make_box must
  # build the cutter and the tenon piece in its entities, beside the boards.
  class FakeParent
    attr_reader :entities

    def initialize
      @entities = Object.new
    end
  end

  # A face of a result; all_connected is the shell it belongs to.
  class FakeFace < Sketchup::Face
    attr_accessor :shell

    def all_connected
      @shell
    end
  end

  # What the handler reads from a board or a result, and the identity it
  # writes back. Only a result's entities (its faces) are read.
  module FakeSolid
    attr_accessor :entityID, :name, :layer, :material, :bounds, :transformation,
                  :parent, :volume, :entities
    attr_writer :manifold, :valid, :definition_name

    def initialize(id, name, bounds, volume, parent)
      @entityID = id
      @name = name
      @layer = Object.new
      @material = nil
      @bounds = bounds
      @volume = volume
      @parent = parent
      @transformation = UNROTATED
      @manifold = true
      @valid = true
      @entities = []
    end

    def manifold?
      @manifold
    end

    def valid?
      @valid
    end

    # Its bounds (in the parent's frame) taken back through its own
    # transformation, as a definition's are for an axis-aligned board; the
    # name is what the Outliner shows for an unnamed instance.
    def definition
      local = F.world_box(@bounds, F.inverse(F.matrix_of(@transformation)))
      BoardDefinition.new(@definition_name,
                          FakeBounds.new(FakePoint.new(*local[0]), FakePoint.new(*local[1])))
    end
  end

  class GroupBoard < Sketchup::Group
    include FakeSolid

    def typename
      "Group"
    end
  end

  class InstanceBoard < Sketchup::ComponentInstance
    include FakeSolid

    def typename
      "ComponentInstance"
    end
  end

  # What make_box returns: the cutter (subtract), then the tenon piece
  # (union). Each records its operand and returns the configured result.
  class FakeTool
    attr_reader :operands, :transforms

    def initialize(result)
      @result = result
      @operands = []
      @transforms = []
    end

    def transform!(transformation)
      @transforms << transformation
      self
    end

    def subtract(other)
      @operands << [:subtract, other]
      @result
    end

    def union(other)
      @operands << [:union, other]
      @result
    end
  end

  # Logs [:start, label], :commit and :abort, and nothing else; finds the
  # registered boards by id. Nothing is open for editing: active_path is nil,
  # as SketchUp's is at the top level.
  class RecordingModel
    attr_reader :log
    attr_accessor :active_path

    def initialize
      @log = []
      @by_id = {}
      @active_path = nil
    end

    def register(*entities)
      entities.each { |e| @by_id[e.entityID] = e }
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

  def mm(*values)
    values.map { |v| v / 25.4 }
  end

  def mm3(value)
    value / 25.4**3
  end

  def bounds_mm(min, max)
    FakeBounds.new(FakePoint.new(*mm(*min)), FakePoint.new(*mm(*max)))
  end

  # n faces that make one shell.
  def shell(n)
    faces = Array.new(n) { FakeFace.new }
    faces.each { |f| f.shell = faces }
    faces
  end

  # A board (or a result) under @parent; corners in mm, volume in mm³.
  def board(klass, id, name, min, max, volume)
    klass.new(id, name, bounds_mm(min, max), mm3(volume), @parent)
  end

  def setup
    @model = RecordingModel.new
    model = @model  # a stub body runs with self == the stubbed module
    stub_singleton(EH, :active_model!) { model }

    @parent = FakeParent.new
    @leg  = board(GroupBoard, 101, "leg",  [0, 0, 0],     [50, 50, 300],  750_000)
    @rail = board(GroupBoard, 102, "rail", [50, 15, 110], [250, 35, 190], 320_000)

    # The results: a solid operation names its group after itself. An edge
    # sits among the faces; only faces count as the shell.
    @pocketed = board(GroupBoard, 201, "Difference", [0, 0, 0],     [50, 50, 300],  742_000)
    @tenoned  = board(GroupBoard, 202, "Union",      [30, 15, 110], [250, 35, 190], 328_000)
    @pocketed.entities = [Object.new, *shell(11)]
    @tenoned.entities  = [Object.new, *shell(10)]
    @cutter = FakeTool.new(@pocketed)
    @piece  = FakeTool.new(@tenoned)

    @box_calls = []
    @tools = []
    calls = @box_calls
    tools = @tools
    stub_singleton(HG, :make_box) do |*args|
      calls << args
      tools.shift
    end
    stub_singleton(F, :transformation) { |m| Marker.new(m) }
  end

  # Puts the boards and the results in a definition placed `copies` times
  # in the model at `matrix`: a group around the boards, closed (its contents
  # in its own frame) or, with the identity, open (SketchUp reports the
  # contents of the open group in world coordinates).
  def parent_at(matrix, copies: 1)
    definition = FrameFakes::Definition.new("Group#1", group: true)
    copies.times { |i| FrameFakes.place(definition, id: 900 + i, parent: Object.new, matrix: matrix) }
    [@leg, @rail, @pocketed, @tenoned].each { |b| b.parent = definition }
    @parent = definition
  end

  # The matrix each tool was transformed by, as markers record it.
  def tool_transforms(tool)
    tool.transforms.map(&:matrix)
  end

  def assert_matrix(expected, actual, tol = 1e-9)
    expected.each_with_index { |v, i| assert_in_delta v, actual[i], tol, "element #{i} of #{actual.inspect}" }
  end

  # Runs the handler on @leg (mortise) and @rail (tenon) with the joint of the
  # probe; params override it. make_box hands out @cutter, then @piece.
  def joint(params = {})
    @model.register(@leg, @rail)
    @tools.replace([@cutter, @piece])
    J.create_mortise_tenon({ "mortise_id" => @leg.entityID.to_s, "tenon_id" => @rail.entityID.to_s,
                             "width" => 10, "height" => 40, "depth" => 20 }.merge(params))
  end

  # make_box was called once per box, in order, each [origin, size] in mm,
  # on the parent's entities.
  def assert_boxes(*boxes)
    assert_equal boxes.size, @box_calls.size, "make_box calls: #{@box_calls.inspect}"
    boxes.zip(@box_calls).each do |(origin, size), (entities, *numbers)|
      assert_same @parent.entities, entities
      assert_equal 6, numbers.size
      mm(*origin, *size).zip(numbers).each do |expected, actual|
        assert_in_delta expected, actual, 1e-9, "make_box #{numbers.inspect}"
      end
    end
  end

  # The tool's one solid operation and its operand.
  def assert_operand(operation, board, tool)
    assert_equal 1, tool.operands.size, "#{operation} calls"
    assert_equal operation, tool.operands[0][0]
    assert_same board, tool.operands[0][1]
  end

  def assert_committed
    assert_equal [[:start, LABEL], :commit], @model.log
  end

  def assert_refused(code, pattern, params = {})
    err = assert_raises(StructuredError) { joint(params) }
    assert_equal code, err.code
    assert_match pattern, err.message
    assert_equal [[:start, LABEL], :abort], @model.log
    err
  end

  # Unsuitable input: -32602 before anything is built.
  def assert_unsuitable(pattern, params = {})
    err = assert_refused(-32602, pattern, params)
    assert_empty @box_calls
    err
  end

  # ---------- the joint ----------

  def test_centred_boards_cut_and_join_and_commit_once
    result = joint

    assert_committed
    pocket = [[30, 20, 130], [20, 10, 40]]
    assert_boxes pocket, pocket
    assert_operand :subtract, @leg, @cutter
    assert_operand :union, @rail, @piece
    assert_equal %w[mortise tenon], result.keys
    assert_equal @pocketed.entityID, result["mortise"]["id"]
    assert_equal @tenoned.entityID, result["tenon"]["id"]
  end

  # describe_entity reads the results' bounds; it must do so before the
  # commit, which can invalidate the proxies of solid-operation results.
  def test_response_is_built_before_the_commit
    log = @model.log
    seen = []
    [@pocketed, @tenoned].each do |result|
      bounds = result.bounds
      result.define_singleton_method(:bounds) do
        seen << log.dup
        bounds
      end
    end

    joint

    assert_committed
    refute_empty seen
    seen.each { |at_read| assert_equal [[:start, LABEL]], at_read }
  end

  def test_offset_rail_joint_is_centred_on_the_contact_area
    @rail.bounds = bounds_mm([50, 0, 200], [250, 20, 280])  # flush with the leg's front, 90 mm higher

    joint

    assert_committed
    pocket = [[30, 5, 220], [20, 10, 40]]
    assert_boxes pocket, pocket
  end

  def test_offsets_move_a_joint_along_z_across_its_cross_axes
    @leg  = board(GroupBoard, 101, "plate", [0, 0, 0],    [200, 200, 50],  2_000_000)
    @rail = board(GroupBoard, 102, "post",  [75, 75, 50], [125, 125, 250],   500_000)
    @pocketed.volume = mm3(1_991_000)  # the joint is 20 x 30 x 15 = 9 000 mm³
    @tenoned.volume  = mm3(509_000)

    # offset_z runs along the joint axis and is ignored.
    joint("width" => 20, "height" => 30, "depth" => 15,
          "offset_x" => 5, "offset_y" => -4, "offset_z" => 99)

    assert_committed
    pocket = [[95, 81, 35], [20, 30, 15]]
    assert_boxes pocket, pocket
  end

  def test_results_keep_the_boards_names_tags_and_materials
    oak = Object.new
    pine = Object.new
    @leg.material = oak
    @rail.material = pine

    result = joint

    assert_equal "leg", @pocketed.name
    assert_same @leg.layer, @pocketed.layer
    assert_same oak, @pocketed.material
    assert_equal "rail", @tenoned.name
    assert_same @rail.layer, @tenoned.layer
    assert_same pine, @tenoned.material
    assert_equal %w[leg rail], [result["mortise"]["name"], result["tenon"]["name"]]
  end

  def test_component_instance_boards_are_accepted
    @leg  = board(InstanceBoard, 101, "leg instance", [0, 0, 0],     [50, 50, 300],  750_000)
    @rail = board(InstanceBoard, 102, "",             [50, 15, 110], [250, 35, 190], 320_000)
    @rail.definition_name = "Rail"  # unnamed: the Outliner shows "Rail"

    result = joint

    assert_committed
    assert_operand :subtract, @leg, @cutter
    assert_operand :union, @rail, @piece
    assert_equal [["group", "leg instance"], ["group", "Rail"]],
                 result.values_at("mortise", "tenon").map { |d| d.values_at("type", "name") }
  end

  # ---------- refused before anything is built ----------

  def test_boards_with_different_parents_are_refused
    @rail.parent = FakeParent.new
    assert_unsuitable(/same group/)
  end

  def test_board_rotated_by_45_degrees_is_refused
    [[@leg, "mortise board"], [@rail, "tenon board"]].each do |rotated, label|
      @model.log.clear
      rotated.transformation = ROTATED_45
      err = assert_unsuitable(/multiple of 90/)
      assert_match(/#{label}/, err.message)
      rotated.transformation = UNROTATED
    end
  end

  def test_board_rotated_by_90_degrees_is_accepted
    @rail.transformation = ROTATED_90
    joint
    assert_committed
  end

  def test_non_solid_board_is_refused
    [[@leg, "mortise board"], [@rail, "tenon board"]].each do |faulty, label|
      @model.log.clear
      faulty.manifold = false
      err = assert_unsuitable(/not a solid/)
      assert_match(/#{label}/, err.message)
      # A board with a tenon nested in it by an earlier version is no solid.
      assert_match(/explode or move out any group or component nested in it/, err.message)
      faulty.manifold = true
    end
  end

  def test_same_board_for_mortise_and_tenon_is_refused
    err = assert_raises(StructuredError) { joint("tenon_id" => @leg.entityID.to_s) }
    assert_equal(-32602, err.code)
    assert_match(/same board/, err.message)
    assert_match(/two different boards/, err.message)
    assert_empty @model.log  # refused before start_operation
    assert_empty @box_calls
  end

  # make_box would merge the corners of a box below SketchUp's merge tolerance.
  def test_joint_dimension_below_the_box_floor_is_refused
    err = assert_raises(StructuredError) { joint("width" => 0.05) }
    assert_equal(-32602, err.code)
    assert_match(/width must be >= 0\.1 mm, got 0\.05/, err.message)
    assert_match(/merge tolerance/, err.message)
    assert_empty @model.log  # refused before start_operation
    assert_empty @box_calls
  end

  def test_separated_boards_are_refused
    @rail.bounds = bounds_mm([60, 15, 110], [260, 35, 190])  # 10 mm off the leg
    assert_unsuitable(/do not touch/)
  end

  def test_joint_too_big_for_the_contact_area_is_refused
    assert_unsuitable(/does not fit/, "width" => 30)  # the rail is 20 mm wide
  end

  # ---------- a group open for editing, and world axes ----------
  #
  # While a group is open, SketchUp reports the instance on the open path
  # with an identity transformation and the transformations and bounds of
  # its contents in world coordinates. The world boxes come out the same
  # open or closed, so the joint does too. A board that is itself open
  # reports an identity transformation, and the solid operations would erase
  # the group the user is working in.

  def test_board_open_for_editing_is_refused
    [[@leg, "mortise board"], [@rail, "tenon board"]].each do |open_board, label|
      @model.log.clear
      @model.active_path = [open_board]
      err = assert_unsuitable(/the #{label} is open for editing/)
      assert_match(/close it and try again/, err.message)
    end
  end

  def test_boards_in_an_open_axis_aligned_group_still_join
    parent_at(F::IDENTITY)                         # open: reported with the identity
    @model.active_path = [@parent.instances.first]
    @leg.transformation = MOVED                    # the boards, seen in world coordinates
    @rail.transformation = MOVED
    @leg.bounds  = bounds_mm([1000, 0, 0],    [1050, 50, 300])
    @rail.bounds = bounds_mm([1050, 15, 110], [1250, 35, 190])

    joint

    assert_committed
    pocket = [[1030, 20, 130], [20, 10, 40]]
    assert_boxes pocket, pocket
  end

  def test_parent_rotated_90_builds_in_world_axes
    turn = F.rotation([0, 0, 0], 2, 90)
    parent_at(turn)
    # Local boxes that the turn puts where the probe's boards are.
    @leg.bounds  = bounds_mm([0, -50, 0],    [50, 0, 300])
    @rail.bounds = bounds_mm([15, -250, 110], [35, -50, 190])

    joint

    assert_committed
    pocket = [[30, 20, 130], [20, 10, 40]]  # in world coordinates, as for the probe
    assert_boxes pocket, pocket
    [@cutter, @piece].each do |tool|
      assert_equal 1, tool.transforms.size
      assert_matrix F.inverse(turn), tool_transforms(tool).first
    end
  end

  def test_open_and_closed_parent_give_the_same_joint
    turn = F.rotation([0, 0, 0], 2, 90)
    parent_at(turn)
    @leg.bounds  = bounds_mm([0, -50, 0],    [50, 0, 300])
    @rail.bounds = bounds_mm([15, -250, 110], [35, -50, 190])
    joint
    closed = @box_calls.map { |_entities, *numbers| numbers }

    # The same group, open: its instance reports the identity, the boards
    # their world transformation and world bounds.
    @box_calls.clear
    @model.log.clear
    @cutter = FakeTool.new(@pocketed)
    @piece  = FakeTool.new(@tenoned)
    parent_at(F::IDENTITY)
    @model.active_path = [@parent.instances.first]
    [@leg, @rail].each { |b| b.transformation = FrameFakes::Transform.new(turn) }
    @leg.bounds  = bounds_mm([0, 0, 0],     [50, 50, 300])
    @rail.bounds = bounds_mm([50, 15, 110], [250, 35, 190])
    joint

    assert_committed
    open = @box_calls.map { |_entities, *numbers| numbers }
    assert_equal closed.size, open.size
    closed.flatten.zip(open.flatten).each { |c, o| assert_in_delta c, o, 1e-9 }
    assert_empty @cutter.transforms, "an open parent is the world frame: nothing to take back"
  end

  def test_parent_rotated_30_is_refused_with_the_model_axes_message
    parent_at(F.rotation([0, 0, 0], 2, 30))
    err = assert_unsuitable(/multiple of 90/)
    assert_equal "the mortise board #{J::ROTATION_MESSAGE}", err.message
  end

  # §6.6a: the boards of an open group rotated by 30° get the same message as
  # with the group closed — not the advice to close it, nor to rotate a
  # board that is placed correctly inside it.
  def test_open_parent_rotated_30_gets_the_same_message
    parent_at(F::IDENTITY)
    @model.active_path = [@parent.instances.first]
    @leg.transformation = ROTATED_30
    @rail.transformation = ROTATED_30
    err = assert_unsuitable(/multiple of 90/)
    assert_equal "the mortise board #{J::ROTATION_MESSAGE}", err.message
  end

  # The boards sit in P beside the group Q that is open inside it.
  def test_boards_beside_an_open_group_get_the_same_message
    parent_at(F::IDENTITY)
    @model.active_path = [@parent.instances.first, Object.new]
    @leg.transformation = ROTATED_30
    @rail.transformation = ROTATED_30
    err = assert_unsuitable(/multiple of 90/)
    assert_equal "the mortise board #{J::ROTATION_MESSAGE}", err.message
  end

  def test_shared_board_is_refused
    parent_at(F::IDENTITY, copies: 2)
    err = assert_unsuitable(/placed 2 times in the model/)
    assert_match(/\Athe mortise board is inside an unnamed group, which is placed 2 times in the model, so changing it would change every copy/,
                 err.message)
  end

  # The parent scales by 2: its contents' volumes, which SketchUp reports in
  # the parent's frame, are an eighth of the world's.
  def scaled_scene
    scale = F.scaling([0, 0, 0], 2, 2, 2)
    parent_at(scale)
    @leg.bounds  = bounds_mm([0, 0, 0],      [25, 25, 150])
    @rail.bounds = bounds_mm([25, 7.5, 55],  [125, 17.5, 95])
    @leg.volume  = mm3(93_750)
    @rail.volume = mm3(40_000)
    scale
  end

  def test_scaled_parent_divides_the_expected_volumes
    scale = scaled_scene
    @pocketed.volume = mm3(92_750)  # the world's 8 000 mm³ pocket is 1 000 here
    @tenoned.volume  = mm3(41_000)

    joint

    assert_committed
    pocket = [[30, 20, 130], [20, 10, 40]]  # make_box works in world coordinates
    assert_boxes pocket, pocket
    assert_matrix F.inverse(scale), tool_transforms(@cutter).first
  end

  def test_scaled_parent_refuses_world_sized_volumes
    scaled_scene
    @pocketed.volume = mm3(85_750)  # 8 000 mm³ gone: eight times the pocket
    @tenoned.volume  = mm3(48_000)
    assert_refused(-32603, /mortise board lost 8000\.0 mm³ \(expected a loss of 1000\.0 mm³\)/)
  end

  # ---------- a solid operation fails: all or nothing ----------
  #
  # Each operation gets its own advice: only the cut depends on the depth
  # against the mortise board's thickness.

  def test_nil_from_subtract_rolls_back
    @cutter = FakeTool.new(nil)
    err = assert_refused(-32603, /could not cut the mortise into the mortise board/)
    assert_match(/thickness/, err.message)
    assert_equal 1, @box_calls.size  # no tenon piece after a failed cut
  end

  def test_nil_from_union_rolls_back
    @piece = FakeTool.new(nil)
    err = assert_refused(-32603, /could not join the tenon to the tenon board/)
    refute_match(/thickness/, err.message)
    assert_equal 2, @box_calls.size  # the cut ran; the union failed
  end

  def test_erased_result_rolls_back
    @pocketed.valid = false
    assert_refused(-32603, /could not cut the mortise into the mortise board/)
  end

  # ---------- the results are checked before the commit ----------

  def test_empty_cut_is_refused_by_the_volume_check
    @pocketed.volume = @leg.volume  # the cut removed nothing
    err = assert_refused(-32603, /was not committed: mortise board lost 0\.0 mm³/)
    refute_match(/-0\.0/, err.message)
    assert_match(/thickness/, err.message)
  end

  # The rail does not fill its box where it touches the leg: the tenon
  # piece overlaps it, and the union adds less than the joint.
  def test_short_tenon_is_refused_by_the_volume_check
    @tenoned.volume = mm3(326_000)
    err = assert_refused(-32603, /was not committed: tenon board gained 6000\.0 mm³/)
    refute_match(/thickness/, err.message)
  end

  def test_tenon_in_two_shells_is_refused
    @tenoned.entities = [Object.new, *shell(6), *shell(6)]
    err = assert_refused(-32603, /was not committed: the tenon did not join the tenon board's body \(it is a separate shell\)/)
    refute_match(/thickness/, err.message)
  end

  # A through mortise as wide as the mortise board cuts it in two: both
  # pieces are closed, and the volume check accepts the loss.
  def test_mortise_board_cut_in_two_is_refused
    @pocketed.entities = [Object.new, *shell(6), *shell(6)]
    err = assert_refused(-32603, /was not committed: the cut split the mortise board into separate pieces/)
    assert_match(/narrower than the mortise board/, err.message)
  end

  # single_shell? finds no shell in a result without faces.
  def test_tenon_without_faces_is_refused
    @tenoned.entities = [Object.new]
    assert_refused(-32603, /the tenon did not join the tenon board's body/)
  end

  def test_non_solid_result_is_refused
    # Only the cut's advice talks about the mortise board's thickness.
    [[@pocketed, "mortise board", true], [@tenoned, "tenon board", false]].each do |result, label, cut|
      @model.log.clear
      result.manifold = false
      err = assert_refused(-32603, /was not committed: the #{label} is no longer a solid/)
      assert_equal cut, err.message.include?("thickness"), err.message
      result.manifold = true
    end
  end

  # A through mortise: the leg is 50 mm thick and the joint 60 deep. The leg
  # loses only the part of the joint inside it; the rail gains all of it.
  def test_through_mortise_is_accepted
    @pocketed.volume = mm3(730_000)  # the leg loses 10 x 40 x 50 = 20 000 mm³
    @tenoned.volume  = mm3(344_000)  # the rail gains 10 x 40 x 60 = 24 000 mm³

    joint("depth" => 60)

    assert_committed
    box = [[-10, 20, 130], [60, 10, 40]]
    assert_boxes box, box
  end

  # The earlier pocket holds part of the new joint's box: the cut frees only
  # the rest, and the new tenon, built on the whole box, would run into the
  # earlier tenon.
  def test_second_pocket_meeting_an_earlier_one_is_refused
    @leg.volume = mm3(742_000)       # a pocket from an earlier joint
    @pocketed.volume = mm3(738_000)  # the new one meets it: the leg loses 4 000 mm³, not 8 000
    err = assert_refused(-32603, /was not committed: mortise board lost 4000\.0 mm³ \(expected a loss of 8000\.0 mm³\)/)
    assert_match(/must not meet an earlier one/, err.message)
  end

  # §6.6a: a shortfall is not the coplanar-faces case the cut's advice is for.
  def test_volume_shortfall_gets_its_own_advice
    @leg.volume = mm3(742_000)
    @pocketed.volume = mm3(738_000)
    err = assert_refused(-32603, /mortise board lost 4000\.0 mm³/)
    assert err.message.end_with?(J::SHORTFALL_ADVICE), err.message
    refute_includes err.message, J::CUT_ADVICE
  end
end

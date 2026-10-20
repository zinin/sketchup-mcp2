# test/test_edge_ops.rb
# M-01, M-07: chamfer_edges / fillet_edges end to end over fakes.
#
# run_edge_op cuts convex feature edges only (select_feature_edges, real
# here: no seam, no concave edge), refuses a closed body that is inside-out
# and a body with nothing left to cut, rolls back with a clear error when
# SketchUp's subtract destroys the body, and stops at the 30 s budget.
#
# Measured in SketchUp 2026.1 on a default cylinder: the subtract on the
# first vertical seam returned nil and invalidated both the cutter and the
# body; the next iteration touched the deleted group and the whole call
# failed with -32603 "reference to deleted Group".
#
# Fakes: a recording model, bodies over EdgeFakes edges and the faces they
# bound, and cutters whose subtract follows a per-test script (see
# FakeCutter). The geometry builders (edge_spec, find_current_edge_spec, the
# two profiles, reconstruct_edge) need Geom and are stubbed, as is
# Entities.active_model!; every stub is restored in teardown.
require "minitest/autorun"

require_relative "support/edge_fakes"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestEdgeOps < Minitest::Test
  include EdgeFakes

  OPS = MCPforSketchUp::Handlers::Operations
  EH  = MCPforSketchUp::Helpers::Entities
  StructuredError = MCPforSketchUp::Core::StructuredError

  FakeBounds = Struct.new(:min, :max)
  BOUNDS = FakeBounds.new(FakePt.new(-50.0, -50.0, 0.0), FakePt.new(50.0, 50.0, 100.0))

  FakeDefinition = Struct.new(:entities)

  # Logs [:start, label], :commit and :abort; find_entity_by_id resolves the
  # registered bodies.
  class RecordingModel
    attr_reader :log

    def initialize
      @log = []
      @by_id = {}
    end

    def register(solid)
      @by_id[solid.entityID] = solid
      solid
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

  # What one test's bodies share: the model, the subtract script and the
  # record of the cuts. It is also every body's parent, so
  # parent.entities.add_group hands out cutters that play the script.
  class Scene
    attr_reader :model, :subtract_calls, :cut_edges

    def initialize
      @model = RecordingModel.new
      @script = []
      @subtract_calls = 0
      @cut_edges = []
      @next_id = 100
    end

    # Outcomes of the coming subtracts, in order; :ok once it runs out.
    def script=(outcomes)
      @script = outcomes.dup
    end

    def body(edges, manifold: true)
      @model.register(FakeBody.new(self, edges, manifold: manifold))
    end

    def instance(edges, manifold: true)
      @model.register(FakeInstance.new(self, edges, manifold: manifold))
    end

    def next_id
      @next_id += 1
    end

    # body.parent.entities
    def entities
      self
    end

    def add_group
      FakeCutter.new(self)
    end

    def take_outcome
      @subtract_calls += 1
      @script.shift || :ok
    end

    # What the profile stubs return; records the edge a cutter is built for.
    def profile_for(spec)
      @cut_edges << spec[:edge]
      FakeProfile.new
    end
  end

  # profile.followme(path) is all run_edge_op asks of a profile face.
  class FakeProfile
    def followme(_path)
      true
    end
  end

  # What FakeBody and FakeInstance share. Like a SketchUp entity, a deleted
  # one raises TypeError on everything but valid?. entityID stays readable so
  # that :ok_stale can model a result that goes stale after run_edge_op
  # cached its ID; `edges` is the test's own view of the body. Its entities
  # are those edges and the faces they bound. `manifold` is what manifold?
  # answers: true for the closed bodies of EdgeFakes.
  module FakeSolid
    attr_reader :entityID, :edges

    def initialize(scene, edges, manifold: true)
      @scene = scene
      @edges = edges
      @manifold = manifold
      @entityID = scene.next_id
      @valid = true
    end

    def valid?
      @valid
    end

    def manifold?
      alive!
      @manifold
    end

    # What SketchUp's subtract does to its operands.
    def invalidate!
      @valid = false
    end

    def parent
      alive!
      @scene
    end

    def transformation
      alive!
      :identity
    end

    def make_unique
      alive!
      self
    end

    def name
      alive!
      ""
    end

    def bounds
      alive!
      BOUNDS
    end

    private

    def alive!
      raise TypeError, "reference to deleted #{typename}" unless @valid
    end

    # The edges, then the faces they bound, as entities holds them.
    def contents
      @edges + @edges.flat_map(&:faces).uniq
    end
  end

  class FakeBody < Sketchup::Group
    include FakeSolid

    def typename
      "Group"
    end

    def entities
      alive!
      contents
    end
  end

  # No entities of its own: the edges and faces live in the definition.
  class FakeInstance < Sketchup::ComponentInstance
    include FakeSolid

    def typename
      "ComponentInstance"
    end

    def definition
      alive!
      FakeDefinition.new(contents)
    end
  end

  # A cutter group. subtract(target) plays the scene's next outcome:
  #   :ok          a new valid body over the same edges; SketchUp erases both
  #                operands
  #   :nil_keep    nil, the body untouched
  #   :nil_destroy nil, and the body and the cutter are gone (the live
  #                failure on a cylinder seam)
  #   :ok_stale    like :ok, but the result is already deleted when used
  class FakeCutter
    def initialize(scene)
      @scene = scene
      @valid = true
    end

    def entities
      :cutter_entities
    end

    def valid?
      @valid
    end

    def erase!
      @valid = false
    end

    def subtract(target)
      outcome = @scene.take_outcome
      case outcome
      when :nil_keep
        nil
      when :nil_destroy
        target.invalidate!
        @valid = false
        nil
      when :ok, :ok_stale
        result = @scene.body(target.edges)
        target.invalidate!
        @valid = false
        result.invalidate! if outcome == :ok_stale
        result
      else
        raise ArgumentError, "unknown subtract outcome #{outcome.inspect}"
      end
    end
  end

  def setup
    @scene = Scene.new
    scene = @scene  # a stub body runs with self == the stubbed module
    @stubs = []
    stub_singleton(EH, :active_model!) { scene.model }
    stub_singleton(OPS, :edge_spec) { |edge, _xform| { edge: edge } }
    # Every edge still matches: the fake cuts change no geometry. The real
    # method starts with entity_collection(entity), so a deleted body raises
    # TypeError here as it does in SketchUp.
    stub_singleton(OPS, :find_current_edge_spec) do |entity, orig, _tolerance|
      EH.entity_collection(entity)
      orig
    end
    stub_singleton(OPS, :build_chamfer_profile) { |_entities, spec, _distance| scene.profile_for(spec) }
    stub_singleton(OPS, :build_fillet_profile) do |_entities, spec, _radius, _segments|
      scene.profile_for(spec)
    end
    stub_singleton(OPS, :reconstruct_edge) { |_entities, _spec| :path }
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

  # Positions in `all` of the edges in `subset`, by identity.
  def positions(all, subset)
    subset.map { |picked| all.index { |e| e.equal?(picked) } }
  end

  def chamfer(target, extra = {})
    OPS.chamfer_edges({ "entity_id" => target.entityID, "distance" => 2 }.merge(extra))
  end

  def fillet(target, extra = {})
    OPS.fillet_edges({ "entity_id" => target.entityID, "radius" => 2 }.merge(extra))
  end

  def stats_slice(res)
    res["stats"].slice("attempted", "succeeded", "skipped_seam", "skipped_concave", "skipped_curved")
  end

  # ---------- feature edges only ----------

  def test_chamfer_cylinder_cuts_rims_and_counts_seams
    edges = EdgeFakes.prism(24)
    res = chamfer(@scene.body(edges))
    assert_equal({ "attempted" => 48, "succeeded" => 48, "skipped_seam" => 24,
                   "skipped_concave" => 0, "skipped_curved" => 0 }, stats_slice(res))
    assert_equal 48, res["edges_chamfered"]
    assert_equal Array(0...48), positions(edges, @scene.cut_edges), "both rims cut, no seam"
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_chamfer_cylinder_with_a_reversed_facet_still_skips_every_seam
    # Live: a default cylinder with one side facet reversed. Its two seams
    # read 165° between the raw normals and were kept; the chamfer kept 50
    # edges and rolled back with -32603 "destroyed the body on edge 49 of 50".
    edges = EdgeFakes.prism(24)
    edges[48].faces[1].reverse!  # side face 0, between the seams 48 and 49
    res = chamfer(@scene.body(edges))
    assert_equal({ "attempted" => 48, "succeeded" => 48, "skipped_seam" => 24,
                   "skipped_concave" => 0, "skipped_curved" => 0 }, stats_slice(res))
    assert_equal Array(0...48), positions(edges, @scene.cut_edges), "both rims cut, no seam"
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_fillet_mixed_body_cuts_only_the_straight_edges
    # Box − cylinder: the box edges are cut, the hole's rims are counted as
    # curved and its walls as seams.
    edges = EdgeFakes.box_with_hole(24)
    res = fillet(@scene.body(edges))
    assert_equal({ "attempted" => 12, "skipped_no_match" => 0, "subtract_failed" => 0,
                   "succeeded" => 12, "skipped_seam" => 24, "skipped_concave" => 0,
                   "skipped_curved" => 48 }, res["stats"])
    assert_equal 12, res["edges_filleted"]
    assert_equal Array(0...12), positions(edges, @scene.cut_edges), "box edges only"
    assert_equal [[:start, "Fillet Edges"], :commit], @scene.model.log
  end

  def test_fillet_cylinder_refuses_without_cutting
    body = @scene.body(EdgeFakes.prism(24))
    err = assert_raises(StructuredError) { fillet(body) }
    assert_equal(-32602, err.code)
    assert_equal "no straight feature edges to fillet on target_id=#{body.entityID} " \
                 "(all 72 edges are surface seams or curved rims)", err.message
    assert_equal [[:start, "Fillet Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_chamfer_all_seam_body_refuses
    # A default sphere: its 496 edges are seams, normals 2.2 .. 22.4° apart.
    body = @scene.body(EdgeFakes.sphere)
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32602, err.code)
    assert_equal "no feature edges to chamfer on target_id=#{body.entityID} " \
                 "(all 496 edges are surface seams)", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_component_instance_target_uses_definition_entities
    # FakeInstance has no #entities: the edges can only come from its
    # definition.
    res = chamfer(@scene.instance(EdgeFakes.prism(24)))
    assert_equal({ "attempted" => 48, "succeeded" => 48, "skipped_seam" => 24,
                   "skipped_concave" => 0, "skipped_curved" => 0 }, stats_slice(res))
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_edge_indices_selecting_only_seams_refuses
    # Direct TCP clients only (the MCP tools do not pass edge_indices). The
    # seam rule applies to the chosen edges: prism(24)'s seams are 48..71.
    body = @scene.body(EdgeFakes.prism(24))
    err = assert_raises(StructuredError) { chamfer(body, "edge_indices" => (48..71).to_a) }
    assert_equal(-32602, err.code)
    assert_equal "no feature edges to chamfer on target_id=#{body.entityID} " \
                 "(all 24 edges are surface seams)", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  # ---------- concave edges ----------

  def test_chamfer_post_leaves_its_concave_base_alone
    # Box ∪ cylinder: live, the post's base rim was cut into the post and
    # counted as succeeded. Edges: the cube's 12, the base rim 12..35, the
    # top rim 36..59, then the post's seams 60..83.
    edges = EdgeFakes.box_with_post(24)
    res = chamfer(@scene.body(edges))
    assert_equal({ "attempted" => 36, "skipped_no_match" => 0, "subtract_failed" => 0,
                   "succeeded" => 36, "skipped_seam" => 24, "skipped_concave" => 24,
                   "skipped_curved" => 0 }, res["stats"])
    assert_equal 36, res["edges_chamfered"]
    assert_equal Array(0...12) + Array(36...60), positions(edges, @scene.cut_edges),
                 "the cube's edges and the post's top rim"
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_fillet_post_counts_each_skipped_edge_once
    # The base rim is concave and curved: it counts as concave only.
    edges = EdgeFakes.box_with_post(24)
    res = fillet(@scene.body(edges))
    assert_equal({ "attempted" => 12, "skipped_no_match" => 0, "subtract_failed" => 0,
                   "succeeded" => 12, "skipped_seam" => 24, "skipped_concave" => 24,
                   "skipped_curved" => 24 }, res["stats"])
    assert_equal Array(0...12), positions(edges, @scene.cut_edges), "the cube's edges only"
    assert_equal [[:start, "Fillet Edges"], :commit], @scene.model.log
  end

  def test_edge_indices_selecting_only_concave_edges_refuses
    # The concave rule applies to the chosen edges: the post's base rim.
    body = @scene.body(EdgeFakes.box_with_post(24))
    err = assert_raises(StructuredError) { chamfer(body, "edge_indices" => (12..35).to_a) }
    assert_equal(-32602, err.code)
    assert_equal "no feature edges to chamfer on target_id=#{body.entityID} " \
                 "(all 24 edges are surface seams or concave edges)", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_fillet_refusal_names_concave_edges
    # The post's edges alone: seams, a curved top rim and a concave base rim.
    body = @scene.body(EdgeFakes.box_with_post(24))
    err = assert_raises(StructuredError) { fillet(body, "edge_indices" => (12..83).to_a) }
    assert_equal(-32602, err.code)
    assert_equal "no straight feature edges to fillet on target_id=#{body.entityID} " \
                 "(all 72 edges are surface seams, curved rims or concave edges)", err.message
    assert_equal [[:start, "Fillet Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  # ---------- an inside-out body ----------
  #
  # Refused by name when it is closed, its faces agree and its signed volume
  # is negative; any other body goes on to the selection.

  # The body with every face turned to point into it, as cones and spheres
  # of earlier builds came out.
  def inside_out(edges)
    edges.flat_map(&:faces).uniq.each(&:reverse!)
    edges
  end

  def inside_out_message(body)
    "target_id=#{body.entityID} is inside-out: its faces point into the body; " \
      "reverse its faces in SketchUp (Reverse Faces / Orient Faces) and retry"
  end

  # The stats of a chamfer on the open-topped box: its 16 convex edges cut,
  # the 8 concave ones round the cavity skipped.
  OPEN_BOX_STATS = { "attempted" => 16, "succeeded" => 16, "skipped_seam" => 0,
                     "skipped_concave" => 8, "skipped_curved" => 0 }.freeze

  def test_chamfer_refuses_an_inside_out_body_by_name
    # Every edge of it reads concave, so it was refused as a body of seams or
    # concave edges: the wrong cause.
    body = @scene.body(inside_out(EdgeFakes.box))
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32602, err.code)
    assert_equal inside_out_message(body), err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_chamfer_refuses_an_inside_out_body_with_concave_edges_by_name
    # Turned inside out, the open-topped box's concave corners read convex:
    # left to the selection, the chamfer would cut into them.
    body = @scene.body(inside_out(EdgeFakes.open_box(5.0)))
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32602, err.code)
    assert_equal inside_out_message(body), err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_fillet_refuses_an_inside_out_instance_by_name
    body = @scene.instance(inside_out(EdgeFakes.box))
    err = assert_raises(StructuredError) { fillet(body) }
    assert_equal(-32602, err.code)
    assert_equal inside_out_message(body), err.message
    assert_equal [[:start, "Fillet Edges"], :abort], @scene.model.log
    assert_equal 0, @scene.subtract_calls
  end

  def test_an_outward_body_is_not_refused
    # The open-topped box as built: closed, its faces agree, its volume is
    # positive.
    res = chamfer(@scene.body(EdgeFakes.open_box(5.0)))
    assert_equal OPEN_BOX_STATS, stats_slice(res)
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_one_reversed_face_is_not_refused
    # One face turned inside out: the faces no longer agree, so the body is
    # not inside-out as a whole. Each face of a box in turn, then the top of
    # a box 1000 above its frame's origin.
    bodies = Array.new(6) do |k|
      edges = EdgeFakes.box
      edges.flat_map(&:faces).uniq[k].reverse!
      edges
    end
    raised = EdgeFakes.prism(4, z0: 1000, z1: 1100)
    raised[4].faces[0].reverse!  # its top
    (bodies << raised).each_with_index do |edges, k|
      assert_equal 12, chamfer(@scene.body(edges))["stats"]["succeeded"], "body #{k}"
    end
    assert_equal [[:start, "Chamfer Edges"], :commit] * 7, @scene.model.log
  end

  def test_one_reversed_face_is_not_refused_even_when_the_volume_reads_negative
    # The open-topped box, 5 thick, with its outer bottom reversed. Measured
    # from the mean of its corners, the bottom spans more than half the thin
    # body, so the signed volume reads negative: 230 500 - 2 * 170 833. The
    # faces disagree, so the sign is not read and the selection takes the
    # body as it is: the edges along the reversed bottom stay convex.
    edges = EdgeFakes.open_box(5.0)
    edges[0].faces[0].reverse!  # the outer bottom
    volume = OPS.signed_volume(edges.flat_map(&:faces).uniq)
    assert_operator volume, :<, 0, "the volume reads negative"
    res = chamfer(@scene.body(edges))
    assert_equal OPEN_BOX_STATS, stats_slice(res)
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  def test_a_body_that_is_not_closed_is_not_checked
    # An open shell has no inside, so neither its orientation nor the sign
    # of its volume is read. This one is inside-out all the same: unchecked,
    # it reaches the selection, which reads every edge as concave.
    checked = []
    stub_singleton(OPS, :consistently_oriented?) do |_edges|
      checked << :orientation
      true
    end
    stub_singleton(OPS, :signed_volume) do |_faces|
      checked << :volume
      -1.0
    end
    body = @scene.body(inside_out(EdgeFakes.box), manifold: false)
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_empty checked, "the inside-out check ran on a body that is not closed"
    assert_equal(-32602, err.code)
    assert_equal "no feature edges to chamfer on target_id=#{body.entityID} " \
                 "(all 12 edges are surface seams or concave edges)", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
  end

  # ---------- a subtract that fails ----------

  def test_destroyed_body_aborts_with_clear_error
    body = @scene.body(EdgeFakes.box)
    @scene.script = %i[ok nil_destroy]
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32603, err.code)
    assert_equal "Chamfer Edges: SketchUp's subtract failed on edge 2 of 12 and destroyed " \
                 "the body; the operation was rolled back, the model is unchanged", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 2, @scene.subtract_calls, "no cut after the body is gone"
  end

  def test_body_deleted_before_a_cut_aborts_with_clear_error
    body = @scene.body(EdgeFakes.box)
    @scene.script = %i[ok_stale]
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32603, err.code)
    assert_equal "Chamfer Edges: SketchUp's subtract failed before edge 2 of 12 and destroyed " \
                 "the body; the operation was rolled back, the model is unchanged", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 1, @scene.subtract_calls
  end

  def test_nil_subtract_that_keeps_body_continues
    @scene.script = %i[ok nil_keep]
    res = chamfer(@scene.body(EdgeFakes.box))
    assert_equal({ "attempted" => 12, "skipped_no_match" => 0, "subtract_failed" => 1,
                   "succeeded" => 11, "skipped_seam" => 0, "skipped_concave" => 0,
                   "skipped_curved" => 0 }, res["stats"])
    assert_equal 11, res["edges_chamfered"]
    assert_equal [[:start, "Chamfer Edges"], :commit], @scene.model.log
  end

  # ---------- the 30 s budget ----------

  def test_budget_exceeded_rolls_back
    body = @scene.body(EdgeFakes.box)
    scene = @scene
    # The clock reads 0 until the first cut, then 31 s.
    stub_singleton(OPS, :monotonic_now) { scene.subtract_calls.zero? ? 0.0 : 31.0 }
    err = assert_raises(StructuredError) { chamfer(body) }
    assert_equal(-32603, err.code)
    assert_equal "Chamfer Edges: stopped after 1 of 12 edges — exceeded the 30 s budget; " \
                 "the operation was rolled back, the model is unchanged", err.message
    assert_equal [[:start, "Chamfer Edges"], :abort], @scene.model.log
    assert_equal 1, @scene.subtract_calls
  end
end

# test/test_edge_selection.rb
# M-01: which edges a chamfer or fillet may cut.
#
# Seams of a tessellated curved surface (faces meeting at less than 25
# degrees) must never be cut: SketchUp's Group#subtract returns nil on one and
# destroys the body. A fillet also cannot round a curved rim one segment at a
# time, so it skips those as well. The selection is pure geometry over
# duck-typed edges (test/support/edge_fakes.rb) and needs no SketchUp.
#
# Dihedral angles below were measured in SketchUp 2026.1 on the default
# primitives: cylinder (24 segments) rims 90 and vertical seams 15; cone seams
# 13.4 and rim 116.4; sphere (16 segments) 496 edges at 2.2 .. 22.4.
require "minitest/autorun"

require_relative "support/edge_fakes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestEdgeSelection < Minitest::Test
  include EdgeFakes

  OPS   = MCPforSketchUp::Handlers::Operations
  UP    = FakeVec.new(0.0, 0.0, 1.0)
  FRONT = FakeVec.new(0.0, -1.0, 0.0)  # 90 degrees from UP

  # ---------- helpers ----------

  # [kept, skipped_seam, skipped_curved] of a selection.
  def counts(sel)
    [sel[:edges].size, sel[:skipped_seam], sel[:skipped_curved]]
  end

  # Positions in `all` of the edges in `subset`, by identity: a failure reads
  # "[0, 1, 48]" instead of dumping fake objects.
  def positions(all, subset)
    subset.map { |picked| all.index { |e| e.equal?(picked) } }
  end

  # Unit normal `deg` degrees away from +Z.
  def tilted(deg)
    rad = deg * Math::PI / 180.0
    FakeVec.new(Math.sin(rad), 0.0, Math.cos(rad))
  end

  # A standalone edge (vertices of its own) on one face per given normal.
  def edge_on(*normals)
    FakeEdge.new(FakeVertex.new(FakePt.new(0.0, 0.0, 0.0)),
                 FakeVertex.new(FakePt.new(0.0, 100.0, 0.0)),
                 normals.map { |normal| FakeFace.new(normal) })
  end

  # A standalone edge whose two faces meet at `deg` degrees.
  def dihedral_edge(deg)
    edge_on(UP, tilted(deg))
  end

  # Two edges meeting at a vertex; the second leaves it turned by `turn_deg`.
  # Both border the same two faces (normals 90 degrees apart, so neither is a
  # seam), or, with same_faces: false, faces of their own.
  def bent_pair(turn_deg, same_faces: true)
    rad = turn_deg * Math::PI / 180.0
    a = FakeVertex.new(FakePt.new(0.0, 0.0, 0.0))
    v = FakeVertex.new(FakePt.new(50.0, 0.0, 0.0))
    b = FakeVertex.new(FakePt.new(50.0 + 50.0 * Math.cos(rad), 50.0 * Math.sin(rad), 0.0))
    faces = [UP, FRONT].map { |normal| FakeFace.new(normal) }
    other = same_faces ? faces : [UP, FRONT].map { |normal| FakeFace.new(normal) }
    [FakeEdge.new(a, v, faces), FakeEdge.new(v, b, other)]
  end

  # ---------- seam_edge? ----------

  def test_seam_threshold_separates_the_measured_primitives
    {
      15.0  => true,   # cylinder: vertical edges
      13.4  => true,   # cone: slanted edges
      2.2   => true,   # sphere: flattest edge
      22.4  => true,   # sphere: sharpest edge
      24.9  => true,   # just under the threshold
      25.1  => false,  # just over it
      30.0  => false,  # 12-sided prism: vertical edges are feature edges
      90.0  => false,  # cylinder rims, box edges
      116.4 => false   # cone rim
    }.each do |deg, seam|
      assert_equal seam, OPS.seam_edge?(dihedral_edge(deg)), "edge meeting at #{deg} degrees"
    end
  end

  def test_boundary_edge_is_not_a_seam
    # One face: the boundary of an open shape. edge_spec rejects it later with
    # -32602; the selection must not hide it as a seam.
    refute OPS.seam_edge?(edge_on(UP))
    assert_equal [1, 0, 0], counts(OPS.select_feature_edges([edge_on(UP)], skip_curved: true))
  end

  def test_loose_and_non_manifold_edges_are_not_seams
    refute OPS.seam_edge?(edge_on), "loose edge, no faces"
    refute OPS.seam_edge?(edge_on(UP, tilted(10.0), tilted(20.0))), "three faces"
  end

  # ---------- select_feature_edges ----------

  def test_cylinder_seams_are_skipped
    edges = EdgeFakes.prism(24)
    sel = OPS.select_feature_edges(edges, skip_curved: false)
    assert_equal 48, sel[:edges].size
    assert_equal 24, sel[:skipped_seam]
    assert_equal 0,  sel[:skipped_curved]
    assert_equal Array(0...48), positions(edges, sel[:edges]),
                 "both rims kept, vertical edges dropped"
  end

  def test_fillet_skips_curved_rims_of_cylinder
    sel = OPS.select_feature_edges(EdgeFakes.prism(24), skip_curved: true)
    assert_empty sel[:edges]
    assert_equal [24, 48], [sel[:skipped_seam], sel[:skipped_curved]]
  end

  def test_box_keeps_all_twelve_edges_in_both_modes
    edges = EdgeFakes.box
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [12, 0, 0], counts(sel), "skip_curved: #{skip_curved}"
      assert_equal Array(0...12), positions(edges, sel[:edges])
    end
  end

  def test_twelve_sided_prism_keeps_all_edges
    # 30 degrees at the vertical edges and 30 degree turns along the rims:
    # both over the 25 degree threshold, so all 36 edges are feature edges.
    edges = EdgeFakes.prism(12)
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [36, 0, 0], counts(sel), "skip_curved: #{skip_curved}"
    end
  end

  def test_sphere_like_body_is_all_seams
    # Default sphere: 496 edges whose faces meet at 2.2 .. 22.4 degrees.
    edges = Array.new(496) { |i| dihedral_edge(2.2 + (22.4 - 2.2) * i / 495.0) }
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [0, 496, 0], counts(sel), "skip_curved: #{skip_curved}"
    end
  end

  def test_mixed_body_keeps_straight_edges_and_flags_hole_rims
    # A box with a cylindrical hole. The hole's rims and walls share no vertex
    # with the box edges, so disjoint fakes model it.
    edges = EdgeFakes.box + EdgeFakes.prism(24)

    chamfer = OPS.select_feature_edges(edges, skip_curved: false)
    assert_equal [60, 24, 0], counts(chamfer)
    assert_equal Array(0...60), positions(edges, chamfer[:edges]), "box edges and both hole rims"

    fillet = OPS.select_feature_edges(edges, skip_curved: true)
    assert_equal [12, 24, 48], counts(fillet)
    assert_equal Array(0...12), positions(edges, fillet[:edges]), "box edges only"
  end

  def test_empty_input_selects_nothing
    [false, true].each do |skip_curved|
      assert_equal [0, 0, 0], counts(OPS.select_feature_edges([], skip_curved: skip_curved))
    end
  end

  def test_selection_keeps_input_order_and_leaves_the_input_alone
    all = (EdgeFakes.box + EdgeFakes.prism(24)).shuffle(random: Random.new(7))
    input = all.dup.freeze
    [false, true].each do |skip_curved|
      kept = positions(all, OPS.select_feature_edges(input, skip_curved: skip_curved)[:edges])
      assert_equal skip_curved ? 12 : 60, kept.size
      assert_equal kept.sort, kept,
                   "kept edges stay in the order given (skip_curved: #{skip_curved})"
    end
  end

  # ---------- curved rims ----------

  def test_collinear_split_edge_is_not_curved
    # One straight edge split in two: the pieces share a vertex and both
    # faces (90 degrees apart) but do not turn at all.
    sel = OPS.select_feature_edges(bent_pair(0.0), skip_curved: true)
    assert_equal [2, 0, 0], counts(sel)
  end

  def test_only_turns_between_the_two_thresholds_make_a_curved_rim
    {
      0.4  => false,  # still collinear (limit 0.5)
      0.6  => true,   # first turn that counts
      10.0 => true,
      24.9 => true,   # last turn under the seam threshold
      25.1 => false,  # a real corner
      90.0 => false
    }.each do |turn, curved|
      assert_equal curved ? 2 : 0, OPS.curved_rim_edges(bent_pair(turn)).size,
                   "turn of #{turn} degrees"
    end
  end

  def test_edges_sharing_a_vertex_but_no_face_are_not_curved
    # The same 10 degree bend is a curved rim on shared faces (see
    # test_only_turns_between_the_two_thresholds_make_a_curved_rim); on faces
    # of their own the edges are unrelated surfaces touching at a point.
    sel = OPS.select_feature_edges(bent_pair(10.0, same_faces: false), skip_curved: true)
    assert_equal [2, 0, 0], counts(sel)
  end

  def test_curved_rim_edges_picks_the_rim_segments_in_input_order
    edges = EdgeFakes.prism(24)  # vertical edges included in the input
    assert_equal Array(0...48), positions(edges, OPS.curved_rim_edges(edges))
    assert_empty OPS.curved_rim_edges(EdgeFakes.box)
    assert_empty OPS.curved_rim_edges(EdgeFakes.prism(12))
  end

  def test_a_curved_rim_segment_needs_its_neighbour_in_the_input
    # edge_indices can pick part of a rim: the rule applies to the chosen edges.
    rim = EdgeFakes.prism(24).first(24)
    assert_equal [0, 1], positions(rim, OPS.curved_rim_edges([rim[0], rim[1]]))
    assert_empty OPS.curved_rim_edges([rim[0], rim[2]]), "a gap between them"
    assert_empty OPS.curved_rim_edges([rim[0]])
  end
end

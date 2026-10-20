# test/test_edge_selection.rb
# M-01, F-1: which edges a chamfer or fillet may cut, and from which side.
#
# Seams of a tessellated curved surface (where the surface bends by less than
# 25 degrees: the two face normals differ by under 25) must never be cut:
# SketchUp's Group#subtract returns nil on one and destroys the body. Concave
# (inside-corner) edges are not cut either: a subtracted wedge cannot chamfer
# or round them, and live it grooved the base of a post instead. A fillet also
# cannot round a curved rim one segment at a time, so it skips those as well.
# Each skipped edge counts under the first of these rules that drops it.
#
# The material side of an edge in each face comes from a probe a little way
# into the face from the edge's midpoint (Face#classify_point), not from the
# face's bounds centre, which lies in the hole on a face with an inner loop.
#
# All of this is pure geometry over duck-typed edges
# (test/support/edge_fakes.rb) and needs no SketchUp.
#
# Angles between face normals, measured in SketchUp 2026.1 on the default
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

  # Geom::Transformation stand-in for a pure translation: moves points by
  # `by` and leaves vectors alone.
  Shift = Struct.new(:by) do
    def *(other)
      return other unless other.is_a?(FakePt)
      FakePt.new(other.x + by.x, other.y + by.y, other.z + by.z)
    end
  end

  # ---------- helpers ----------

  # [kept, skipped_seam, skipped_concave, skipped_curved] of a selection.
  def counts(sel)
    [sel[:edges].size, sel[:skipped_seam], sel[:skipped_concave], sel[:skipped_curved]]
  end

  # Positions in `all` of the edges in `subset`, by identity: a failure reads
  # "[0, 1, 48]" instead of dumping fake objects.
  def positions(all, subset)
    subset.map { |picked| all.index { |e| e.equal?(picked) } }
  end

  # The distinct faces of a body, in the order its edges first list them.
  def faces_of(edges)
    edges.flat_map(&:faces).uniq
  end

  def pt(x, y, z = 0.0)
    FakePt.new(x.to_f, y.to_f, z.to_f)
  end

  # The coordinates of a point or vector, equal to `expected` within rounding.
  def assert_xyz(expected, actual, message = nil)
    assert_equal expected.map { |c| c.to_f.round(9) },
                 [actual.x, actual.y, actual.z].map { |c| c.round(9) }, message
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

  # A top face (normal UP) with the path through `vertices` as one side and
  # the rest of it at +y, up to y = 100.
  def top_beside(*vertices)
    path = vertices.map(&:position)
    FakeFace.new(UP, [path + [pt(path.last.x, 100), pt(path.first.x, 100)]])
  end

  # Two edges meeting at a vertex; the second leaves it turned by `turn_deg`.
  # Both border the same two faces (normals 90 degrees apart, so neither is a
  # seam), or, with same_faces: false, faces of their own. Each edge is a
  # convex corner, like a box's, between a top face spreading to +y and a
  # front face; the front faces are normals only, as only faces[0] is probed.
  def bent_pair(turn_deg, same_faces: true)
    rad = turn_deg * Math::PI / 180.0
    a = FakeVertex.new(FakePt.new(0.0, 0.0, 0.0))
    v = FakeVertex.new(FakePt.new(50.0, 0.0, 0.0))
    b = FakeVertex.new(FakePt.new(50.0 + 50.0 * Math.cos(rad), 50.0 * Math.sin(rad), 0.0))
    if same_faces
      faces = [top_beside(a, v, b), FakeFace.new(FRONT)]
      [FakeEdge.new(a, v, faces), FakeEdge.new(v, b, faces)]
    else
      [FakeEdge.new(a, v, [top_beside(a, v), FakeFace.new(FRONT)]),
       FakeEdge.new(v, b, [top_beside(v, b), FakeFace.new(FRONT)])]
    end
  end

  # The top of a block at z = 0, 100 x 100, with a 40 x 40 hole through the
  # middle: its bounds centre (50, 50) lies in the hole.
  def holed_square
    loops = [[[0, 0], [100, 0], [100, 100], [0, 100]],
             [[30, 30], [70, 30], [70, 70], [30, 70]]]
    FakeFace.new(UP, loops.map { |loop| loop.map { |x, y| pt(x, y) } })
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
    assert_equal [1, 0, 0, 0], counts(OPS.select_feature_edges([edge_on(UP)], skip_curved: true))
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
      assert_equal [12, 0, 0, 0], counts(sel), "skip_curved: #{skip_curved}"
      assert_equal Array(0...12), positions(edges, sel[:edges])
    end
  end

  def test_twelve_sided_prism_keeps_all_edges
    # 30 degrees at the vertical edges and 30 degree turns along the rims:
    # both over the 25 degree threshold, so all 36 edges are feature edges.
    edges = EdgeFakes.prism(12)
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [36, 0, 0, 0], counts(sel), "skip_curved: #{skip_curved}"
    end
  end

  def test_sphere_like_body_is_all_seams
    # Default sphere: 496 edges whose faces meet at 2.2 .. 22.4 degrees.
    edges = Array.new(496) { |i| dihedral_edge(2.2 + (22.4 - 2.2) * i / 495.0) }
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [0, 496, 0, 0], counts(sel), "skip_curved: #{skip_curved}"
    end
  end

  def test_mixed_body_keeps_straight_edges_and_flags_hole_rims
    # Box − cylinder: the cube's 12 edges, the hole's bottom rim 12..35, its
    # top rim 36..59, then its seams 60..83. The rims are convex, although
    # the bounds centres of the cube's top and bottom lie in the hole. The
    # wall bends inward at its seams; they count as seams, the first rule.
    edges = EdgeFakes.box_with_hole(24)

    chamfer = OPS.select_feature_edges(edges, skip_curved: false)
    assert_equal [60, 24, 0, 0], counts(chamfer)
    assert_equal Array(0...60), positions(edges, chamfer[:edges]), "box edges and both hole rims"

    fillet = OPS.select_feature_edges(edges, skip_curved: true)
    assert_equal [12, 24, 0, 48], counts(fillet)
    assert_equal Array(0...12), positions(edges, fillet[:edges]), "box edges only"
  end

  def test_empty_input_selects_nothing
    [false, true].each do |skip_curved|
      assert_equal [0, 0, 0, 0], counts(OPS.select_feature_edges([], skip_curved: skip_curved))
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
    assert_equal [2, 0, 0, 0], counts(sel)
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
    assert_equal [2, 0, 0, 0], counts(sel)
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

  # ---------- concave edges ----------

  def test_post_base_rim_is_concave_and_counted_once
    # Box ∪ cylinder, where a chamfer grooved the post along its base live:
    # the cube's 12 edges, the post's base rim 12..35, its top rim 36..59,
    # then its seams 60..83.
    edges = EdgeFakes.box_with_post(24)

    chamfer = OPS.select_feature_edges(edges, skip_curved: false)
    assert_equal [36, 24, 24, 0], counts(chamfer)
    assert_equal Array(0...12) + Array(36...60), positions(edges, chamfer[:edges]),
                 "the cube's edges and the post's top rim"

    fillet = OPS.select_feature_edges(edges, skip_curved: true)
    assert_equal [12, 24, 24, 24], counts(fillet), "the base rim counts as concave, not as curved too"
    assert_equal Array(0...12), positions(edges, fillet[:edges])
  end

  def test_l_block_inner_corner_is_concave
    # The end faces are L-shaped, with their bounds centres at the inner
    # corner; the edges beside it are convex all the same.
    edges = EdgeFakes.l_block
    [false, true].each do |skip_curved|
      sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
      assert_equal [17, 0, 1, 0], counts(sel), "skip_curved: #{skip_curved}"
      assert_equal Array(0...18) - [15], positions(edges, sel[:edges])
    end
  end

  def test_only_an_edge_between_two_faces_can_be_concave
    refute OPS.concave_edge?(edge_on), "loose edge, no faces"
    refute OPS.concave_edge?(edge_on(UP)), "boundary edge"
    refute OPS.concave_edge?(edge_on(UP, tilted(10.0), tilted(20.0))), "three faces"
  end

  def test_one_reversed_face_does_not_make_convex_edges_concave
    # A face turned inside out has its normal pointing into the body. Judged
    # from one direction alone, an edge whose second face was the reversed one
    # read as concave: 3 of a box's 12 edges were skipped, and which ones
    # depended on the order of the edge's face list. Both directions must say
    # so, and with a single bad face one of them always says no.
    concave = ->(list) { list.each_index.select { |i| OPS.concave_edge?(list[i]) } }
    assert_equal 6, faces_of(EdgeFakes.box).size, "a box has six faces"
    6.times do |k|
      edges = EdgeFakes.box
      faces_of(edges)[k].reverse!
      swapped = edges.map { |edge| FakeEdge.new(edge.start, edge.end, edge.faces.reverse) }
      assert_empty concave.call(edges), "face #{k} reversed: edges read as concave"
      assert_empty concave.call(swapped), "face #{k} reversed, faces swapped: edges read as concave"
      [false, true].each do |skip_curved|
        sel = OPS.select_feature_edges(edges, skip_curved: skip_curved)
        assert_equal [12, 0, 0, 0], counts(sel), "face #{k} reversed, skip_curved: #{skip_curved}"
      end
    end
  end

  # ---------- the side of a cut ----------

  def test_perp_points_into_the_material_beside_a_hole
    face = holed_square
    along_y = FakeVec.new(0.0, 1.0, 0.0)
    assert_equal Sketchup::Face::PointOutside, face.classify_point(face.bounds.center),
                 "the bounds centre lies in the hole"
    assert_xyz [1, 0, 0], OPS.in_face_perp_inward(face, pt(70, 50), along_y), "hole side x = 70"
    assert_xyz [-1, 0, 0], OPS.in_face_perp_inward(face, pt(30, 50), along_y), "hole side x = 30"
    assert_xyz [-1, 0, 0], OPS.in_face_perp_inward(face, pt(100, 50), along_y), "outer side x = 100"
  end

  def test_perp_falls_back_to_the_bounds_centre_when_no_probe_lands_inside
    # A face too narrow for the probe, here a strip 0.004 wide on either
    # side of the edge y = 0: the bounds centre decides, as it did before the
    # probe. classify_point is stubbed so that this holds for any probe
    # distance.
    along_x = FakeVec.new(1.0, 0.0, 0.0)
    { 0.004 => [0, 1, 0], -0.004 => [0, -1, 0] }.each do |width, expected|
      strip = FakeFace.new(UP, [[pt(0, 0), pt(100, 0), pt(100, width), pt(0, width)]])
      strip.define_singleton_method(:classify_point) { |_point| Sketchup::Face::PointOutside }
      assert_xyz expected, OPS.in_face_perp_inward(strip, pt(50, 0), along_x), "strip at y #{width}"
    end
  end

  def test_edge_spec_takes_both_perpendiculars_from_the_material_side
    # The hole's top rim in box − cylinder, its segment from 0 to 15 degrees
    # around the hole: perp1 runs along the cube's top away from the hole,
    # perp2 down the hole's wall. The group sits 1000 along x; the faces are
    # still probed in the edge's own coordinates.
    rim = EdgeFakes.box_with_hole(24)[36]
    spec = OPS.edge_spec(rim, Shift.new(FakeVec.new(1000.0, 0.0, 0.0)))
    away = 7.5 * Math::PI / 180.0
    assert_xyz [Math.cos(away), Math.sin(away), 0], spec[:perp1], "along the top, away from the hole"
    assert_xyz [0, 0, -1], spec[:perp2], "down the wall"
    assert_xyz [1070, 50, 100], spec[:start_pos]
  end
end

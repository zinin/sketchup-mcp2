# test/support/edge_fakes.rb
# Duck-typed edges, faces and vertices for the edge ops of
# Handlers::Operations, reusable by any test that feeds a body's edges to
# them: the feature-edge selection (seam_edge?, concave_edge?,
# curved_rim_edges, select_feature_edges), the side of a cut
# (in_face_perp_inward, edge_spec) and the inside-out check
# (signed_volume). What they model:
#   Edge#faces, #vertices, #start, #end, #other_vertex, #reversed_in?
#   Vertex#position
#   Face#normal, #area, #vertices, #classify_point, #bounds, #reverse!
#   Point3d#-, #offset, #x, #y, #z
#   Vector3d#angle_between, #cross, #dot, #length, #length=, #reverse
# Nothing else: no entity IDs, no materials, no transformations.
#
# Vertices, faces and edges are plain objects, NOT Structs: in SketchUp an
# entity is its identity, so two vertices at the same position are still two
# vertices. Struct equality is by value and would merge them.
#
# A face is its normal and its loops of points: the outer loop, then one per
# hole, wound as SketchUp winds them, the outer loop counterclockwise seen
# from the side the normal points to and every hole clockwise. The
# constructor refuses a loop wound the other way, so no fixture holds a face
# whose normal disagrees with its loops, and two faces of a body built that
# way run every edge they share in opposite directions. What a face answers
# comes from its loops: #classify_point, #bounds, #area, #vertices, and
# Edge#reversed_in? (true when the face's loop runs the edge from its end to
# its start). #reverse! turns a face inside out as Face#reverse! does: the
# normal flips and every loop runs the other way. A face built from a normal
# alone has nothing to probe and raises if asked.
#
# Constructors: FakeVertex.new(position), FakeFace.new(normal, loops),
# FakeEdge.new(start_vertex, end_vertex, faces). EdgeFakes.facet makes a face
# whose normal follows from the winding of its loop, EdgeFakes.mesh a body
# of such faces with the edges they share.
#
# The Sketchup stubs are guarded: other test files define their own empty
# Sketchup::Edge / Sketchup::Face, and under run_all every file loads before
# any test runs, so this file must not depend on load order. FakeEdge and
# FakeFace subclass them so that entities.grep(Sketchup::Edge) sees the fakes.
# The classify_point results are guarded constants of whichever Sketchup::Face
# loaded first; the code compares with the constants, never with their values.
module Sketchup
  class Edge; end unless defined?(Edge)
  class Face; end unless defined?(Face)
end

{ PointInside: 1, PointOnEdge: 4, PointOutside: 8, PointNotOnPlane: 16 }.each do |name, value|
  Sketchup::Face.const_set(name, value) unless Sketchup::Face.const_defined?(name, false)
end

module EdgeFakes
  RADIUS = 50.0

  # Geom::Vector3d stand-in.
  FakeVec = Struct.new(:x, :y, :z) do
    # Radians in 0..PI, like Geom::Vector3d#angle_between. atan2 of the cross
    # product's length and the dot product stays accurate for near-parallel
    # vectors (acos of a rounded dot product does not), which is where the
    # 0.5 degree collinear tolerance lives.
    def angle_between(other)
      Math.atan2(cross(other).length, dot(other))
    end

    def dot(other)
      x * other.x + y * other.y + z * other.z
    end

    def cross(other)
      FakeVec.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    end

    # The vector's length, not Struct#length (the number of members).
    def length
      Math.sqrt(dot(self))
    end

    # Rescales the vector in place, like Geom::Vector3d#length=.
    def length=(new_length)
      scale = new_length / length
      self.x *= scale
      self.y *= scale
      self.z *= scale
    end

    def reverse
      FakeVec.new(-x, -y, -z)
    end
  end

  # Geom::Point3d stand-in: Point3d - Point3d is a Vector3d.
  FakePt = Struct.new(:x, :y, :z) do
    def -(other)
      FakeVec.new(x - other.x, y - other.y, z - other.z)
    end

    # Like Geom::Point3d#offset: the point moved along `vec` by `distance`,
    # or by `vec` itself without one.
    def offset(vec, distance = nil)
      scale = distance.nil? ? 1.0 : distance / vec.length
      FakePt.new(x + vec.x * scale, y + vec.y * scale, z + vec.z * scale)
    end
  end

  # Geom::BoundingBox stand-in, as far as Face#bounds goes.
  FakeBBox = Struct.new(:min, :max) do
    def center
      FakePt.new((min.x + max.x) / 2.0, (min.y + max.y) / 2.0, (min.z + max.z) / 2.0)
    end
  end

  # The vector area of a closed loop of points (Newell's method): as long as
  # the area the loop encloses, pointing to the side from which the loop is
  # seen to run counterclockwise.
  def self.vector_area(points)
    sum = FakeVec.new(0.0, 0.0, 0.0)
    points.each_index do |i|
      a = points[i]
      b = points[(i + 1) % points.size]
      sum.x += a.y * b.z - a.z * b.y
      sum.y += a.z * b.x - a.x * b.z
      sum.z += a.x * b.y - a.y * b.x
    end
    FakeVec.new(sum.x / 2.0, sum.y / 2.0, sum.z / 2.0)
  end

  class FakeVertex
    attr_reader :position

    def initialize(position)
      @position = position
    end
  end

  class FakeFace < Sketchup::Face
    # SketchUp's length tolerance, in inches: a point this close to a side
    # is on it.
    TOLERANCE = 0.001

    attr_reader :normal

    # `loops`: lists of FakePt, the outer loop first, then one per hole,
    # each in order around it: the outer loop counterclockwise seen from
    # where `normal` points, a hole clockwise. Raises for a loop wound the
    # other way.
    def initialize(normal, loops = [])
      @normal = normal
      @loops = loops
      loops.each_with_index do |loop, k|
        counterclockwise = EdgeFakes.vector_area(loop).dot(normal) > 0
        next if counterclockwise == k.zero?
        raise ArgumentError, "loop #{k} of a face with normal #{normal.to_a} is wound the " \
                             "wrong way: the outer loop runs counterclockwise around the " \
                             "normal, a hole clockwise"
      end
    end

    # Like Face#area: what the outer loop encloses, less its holes. A hole
    # winds the other way, so its vector area counts against the outer one.
    def area
      geometry.sum { |loop| EdgeFakes.vector_area(loop).dot(@normal) } / @normal.length
    end

    # Like Face#vertices: one per corner of each loop, in loop order. They
    # are made afresh over the loop points and shared with no edge, so only
    # their positions mean anything.
    def vertices
      geometry.flatten(1).map { |point| FakeVertex.new(point) }
    end

    # Like Face#bounds: the bounding box of the outer loop.
    def bounds
      outer = geometry.first
      FakeBBox.new(FakePt.new(*%i[x y z].map { |axis| outer.map(&axis).min }),
                   FakePt.new(*%i[x y z].map { |axis| outer.map(&axis).max }))
    end

    # Like Face#classify_point, for a point in the face's own coordinates:
    # off its plane, on a side of a loop, else inside or outside by the
    # even-odd rule over all the loops, so a point in a hole is outside.
    def classify_point(point)
      loops = geometry
      if (point - loops.first.first).dot(@normal).abs > TOLERANCE
        Sketchup::Face::PointNotOnPlane
      elsif loops.any? { |loop| on_a_side?(loop, point) }
        Sketchup::Face::PointOnEdge
      elsif loops.sum { |loop| crossings(loop, point) }.odd?
        Sketchup::Face::PointInside
      else
        Sketchup::Face::PointOutside
      end
    end

    # Like Face#reverse!: the face turns inside out. Its normal points the
    # other way, and every loop runs the other way round.
    def reverse!
      @normal = @normal.reverse
      @loops = @loops.map(&:reverse)
      self
    end

    # True when points `a` and `b` are the two ends of a side of a loop.
    # Fixture plumbing for EdgeFakes.edges_on, not SketchUp API.
    def side?(a, b)
      @loops.any? do |loop|
        sides(loop).any? { |from, to| (from == a && to == b) || (from == b && to == a) }
      end
    end

    # True when a loop has a side from point `from` to point `to`, run in
    # that direction. Fixture plumbing for FakeEdge#reversed_in?.
    def runs?(from, to)
      geometry.any? { |loop| sides(loop).include?([from, to]) }
    end

    private

    def geometry
      raise ArgumentError, "this FakeFace has a normal only, no loops to probe" if @loops.empty?
      @loops
    end

    # [from, to] for each side of a closed loop.
    def sides(loop)
      loop.each_index.map { |i| [loop[i], loop[(i + 1) % loop.size]] }
    end

    def on_a_side?(loop, point)
      sides(loop).any? do |from, to|
        side = to - from
        along = ((point - from).dot(side) / side.dot(side)).clamp(0.0, 1.0)
        (point - from.offset(side, side.length * along)).length <= TOLERANCE
      end
    end

    # How many sides of `loop` a ray from `point` crosses, in the plane of
    # the two axes the normal leans on least.
    def crossings(loop, point)
      u, v = [0, 1, 2] - [[0, 1, 2].max_by { |axis| @normal[axis].abs }]
      sides(loop).count do |from, to|
        next false if (from[v] > point[v]) == (to[v] > point[v])
        point[u] < from[u] + (point[v] - from[v]) * (to[u] - from[u]) / (to[v] - from[v])
      end
    end
  end

  class FakeEdge < Sketchup::Edge
    attr_reader :start, :end, :faces

    def initialize(start_vertex, end_vertex, faces)
      @start = start_vertex
      @end = end_vertex
      @faces = faces
    end

    def vertices
      [@start, @end]
    end

    # Like Sketchup::Edge#other_vertex: nil for a vertex that is not an end.
    def other_vertex(vertex)
      if vertex.equal?(@start)
        @end
      elsif vertex.equal?(@end)
        @start
      end
    end

    # Like Sketchup::Edge#reversed_in?: true when `face`'s loop runs this
    # edge from its end to its start, false when from its start to its end.
    def reversed_in?(face)
      from = @start.position
      to = @end.position
      return false if face.runs?(from, to)
      return true if face.runs?(to, from)
      raise ArgumentError, "this FakeEdge is not a side of that face"
    end
  end

  def self.vertex(x, y, z)
    FakeVertex.new(FakePt.new(x.to_f, y.to_f, z.to_f))
  end

  # n vertices evenly around a circle of `radius` at height z, centred on
  # (cx, cy), counterclockwise from angle 0.
  def self.ring(n, radius, z, cx = 0.0, cy = 0.0)
    step = 2 * Math::PI / n
    Array.new(n) { |i| vertex(cx + radius * Math.cos(i * step), cy + radius * Math.sin(i * step), z) }
  end

  # The 3n edges of a regular n-gon prism (radius RADIUS, from z0 up to z1)
  # with real normals: caps (0, 0, -1) and (0, 0, 1), each side face facing
  # outward at its mid-angle. Listed like a default SketchUp cylinder: the
  # bottom rim (n edges), the top rim (n edges), then the n vertical edges,
  # so the seams of prism(24) sit at indices 48..71. Every call builds its own
  # vertices and faces, so two prisms never share an entity.
  #
  # Angles between normals: rims 90 degrees, vertical edges 360 / n degrees.
  def self.prism(n, z0: 0, z1: 100)
    raise ArgumentError, "a prism needs at least 3 sides, got #{n}" if n < 3

    step = 2 * Math::PI / n
    bottom = ring(n, RADIUS, z0)
    top    = ring(n, RADIUS, z1)

    # The bottom ring runs counterclockwise seen from above, so clockwise
    # seen from below, where the bottom cap's normal points: reversed.
    cap_bottom = FakeFace.new(FakeVec.new(0.0, 0.0, -1.0), [bottom.map(&:position).reverse])
    cap_top    = FakeFace.new(FakeVec.new(0.0, 0.0, 1.0), [top.map(&:position)])
    sides = Array.new(n) do |i|
      mid = (i + 0.5) * step
      corners = [bottom[i], bottom[(i + 1) % n], top[(i + 1) % n], top[i]]
      FakeFace.new(FakeVec.new(Math.cos(mid), Math.sin(mid), 0.0), [corners.map(&:position)])
    end

    bottom_rim = Array.new(n) do |i|
      FakeEdge.new(bottom[i], bottom[(i + 1) % n], [cap_bottom, sides[i]])
    end
    top_rim = Array.new(n) do |i|
      FakeEdge.new(top[i], top[(i + 1) % n], [cap_top, sides[i]])
    end
    # Vertical edge i joins side faces i - 1 and i.
    vertical = Array.new(n) do |i|
      FakeEdge.new(bottom[i], top[i], [sides[(i - 1) % n], sides[i]])
    end

    bottom_rim + top_rim + vertical
  end

  def self.box
    prism(4)
  end

  # ---------- bodies of facets ----------

  # A face over one loop of points, its normal following from their order:
  # it points to the side from which the loop runs counterclockwise.
  def self.facet(points)
    normal = vector_area(points)
    normal.length = 1.0
    FakeFace.new(normal, [points])
  end

  # The edges of a body of facets, each given as a loop of vertices wound
  # counterclockwise seen from outside: one edge per pair of vertices next
  # to each other in a loop, on the facets that share it, in the order the
  # loops first reach it. An edge runs the way the first of those loops
  # does.
  def self.mesh(loops)
    faces = loops.map { |loop| facet(loop.map(&:position)) }
    by_pair = {}
    loops.each_with_index do |loop, k|
      ring_sides(loop).each do |from, to|
        key = [from.object_id, to.object_id].sort
        (by_pair[key] ||= [from, to, []])[2] << faces[k]
      end
    end
    by_pair.values.map { |from, to, sharing| FakeEdge.new(from, to, sharing) }
  end

  # A default SketchUp cone, as create_component builds it (24 segments,
  # diameter 100, height 100): the base and n triangles up to the apex, all
  # facing outward. Edges: the base rim (n edges, 116.4 degrees between
  # normals for n = 24), then the n slanted seams (13.4 degrees).
  def self.cone(n = 24)
    base = ring(n, RADIUS, 0.0)
    apex = vertex(0, 0, 2 * RADIUS)
    # The base ring runs counterclockwise seen from above; its face looks
    # down, so its loop is reversed.
    mesh([base.reverse] + Array.new(n) { |i| [base[i], base[(i + 1) % n], apex] })
  end

  # A default SketchUp sphere, as create_component builds it (16 segments,
  # diameter 100): a pole at the top and the bottom with n - 1 rings of n
  # vertices between them, a fan of triangles at each pole and quads
  # between the rings, all facing outward. For n = 16: 256 faces and 496
  # edges, every one a seam (2.2 .. 22.4 degrees between normals).
  def self.sphere(n = 16)
    north = vertex(0, 0, RADIUS)
    south = vertex(0, 0, -RADIUS)
    rings = (1...n).map do |k|
      latitude = Math::PI * k / n
      ring(n, RADIUS * Math.sin(latitude), RADIUS * Math.cos(latitude))
    end
    loops = []
    n.times do |j|
      k = (j + 1) % n
      loops << [north, rings.first[j], rings.first[k]]
      rings.each_cons(2) { |upper, lower| loops << [upper[j], lower[j], lower[k], upper[k]] }
      loops << [south, rings.last[k], rings.last[j]]
    end
    mesh(loops)
  end

  # ---------- composite bodies ----------
  # Built face by face; edges_on finds each edge's faces. CUBE is the side of
  # the cube under box_with_post and box_with_hole (0..CUBE on every axis),
  # the bodies of the live chamfer failure: box ∪ cylinder, box − cylinder.

  CUBE = 100.0
  FEATURE_RADIUS = 20.0

  # A face with this normal (an [x, y, z] array) over loops of vertices: the
  # outer loop first, then the holes.
  def self.face(normal, *loops)
    FakeFace.new(FakeVec.new(*normal.map(&:to_f)), loops.map { |loop| loop.map(&:position) })
  end

  # One edge per [start, end] pair of vertices, in that order, on every face
  # that has the pair as a side of a loop, in the order of `faces`.
  def self.edges_on(faces, pairs)
    pairs.map do |from, to|
      FakeEdge.new(from, to, faces.select { |face| face.side?(from.position, to.position) })
    end
  end

  # The sides of a closed ring of vertices, as [start, end] pairs.
  def self.ring_sides(ring)
    ring.each_index.map { |i| [ring[i], ring[(i + 1) % ring.size]] }
  end

  # The faces and edge pairs of the cube, a ring of vertices as an inner loop
  # of its top or bottom face if given. The top and the bottom come first in
  # the faces, so an edge of such a ring lists that face as faces[0]. The
  # edges come like prism's: bottom, top, then vertical. A ring runs
  # counterclockwise seen from above: right for a hole in the bottom face,
  # which looks down, and reversed for one in the top.
  def self.cube(top_hole: nil, bottom_hole: nil)
    corners = [[0.0, 0.0], [CUBE, 0.0], [CUBE, CUBE], [0.0, CUBE]]
    bottom = corners.map { |x, y| vertex(x, y, 0.0) }
    top    = corners.map { |x, y| vertex(x, y, CUBE) }
    faces = [face([0, 0, 1], *[top, top_hole&.reverse].compact),
             face([0, 0, -1], *[bottom.reverse, bottom_hole].compact)]
    [[0, -1, 0], [1, 0, 0], [0, 1, 0], [-1, 0, 0]].each_with_index do |normal, i|
      j = (i + 1) % 4
      faces << face(normal, [bottom[i], bottom[j], top[j], top[i]])
    end
    [faces, ring_sides(bottom) + ring_sides(top) + bottom.zip(top)]
  end

  # The n wall faces of a round feature between two rings: facing away from
  # its axis for a post, toward it for a hole (whose material is outside).
  def self.walls(low, high, outward:)
    n = low.size
    sign = outward ? 1.0 : -1.0
    Array.new(n) do |i|
      mid = (i + 0.5) * 2 * Math::PI / n
      j = (i + 1) % n
      corners = [low[i], low[j], high[j], high[i]]
      face([sign * Math.cos(mid), sign * Math.sin(mid), 0.0], outward ? corners : corners.reverse)
    end
  end

  # Box ∪ cylinder: an n-sided post of radius FEATURE_RADIUS, 50 tall,
  # standing in the middle of the cube's top. The top face holds the post's
  # footprint as an inner loop, so its bounds centre lies inside the post.
  # Edges: the cube's 12, the post's base rim (n, concave), its top rim (n),
  # then its n vertical seams. The base rim lists the cube's top as faces[0].
  def self.box_with_post(n)
    middle = CUBE / 2
    base = ring(n, FEATURE_RADIUS, CUBE, middle, middle)
    head = ring(n, FEATURE_RADIUS, CUBE + 50.0, middle, middle)
    faces, pairs = cube(top_hole: base)
    faces << face([0, 0, 1], head)
    faces.concat(walls(base, head, outward: true))
    edges_on(faces, pairs + ring_sides(base) + ring_sides(head) + base.zip(head))
  end

  # Box − cylinder: an n-sided hole of radius FEATURE_RADIUS through the
  # middle of the cube, top to bottom. The top and bottom faces hold its rims
  # as inner loops, so their bounds centres lie in the hole. Edges: the
  # cube's 12, the hole's bottom rim (n), its top rim (n), then its n vertical
  # seams. The rims list the cube's top or bottom as faces[0]; all but the
  # seams are convex.
  def self.box_with_hole(n)
    middle = CUBE / 2
    low  = ring(n, FEATURE_RADIUS, 0.0, middle, middle)
    high = ring(n, FEATURE_RADIUS, CUBE, middle, middle)
    faces, pairs = cube(top_hole: high, bottom_hole: low)
    faces.concat(walls(low, high, outward: false))
    edges_on(faces, pairs + ring_sides(low) + ring_sides(high) + low.zip(high))
  end

  # An L-shaped block: the profile (0,0) (100,0) (100,50) (50,50) (50,100)
  # (0,100) in the xz-plane, extruded from y = 0 to y = 100. Its two end faces
  # are L-shaped, with their bounds centres at the inner corner. Edges: the
  # near end's 6, the far end's 6, then the 6 along y, of which index 15, at
  # the inner corner (50, y, 50), is concave.
  def self.l_block
    profile = [[0, 0], [100, 0], [100, 50], [50, 50], [50, 100], [0, 100]]
    near = profile.map { |x, z| vertex(x, 0, z) }
    far  = profile.map { |x, z| vertex(x, 100, z) }
    # The profile runs counterclockwise seen from the near side (-y), so
    # clockwise from the far side: the far end's loop is reversed.
    faces = [face([0, -1, 0], near), face([0, 1, 0], far.reverse)]
    # The outward normal of the long face from profile point k to k + 1.
    [[0, 0, -1], [1, 0, 0], [0, 0, 1], [1, 0, 0], [0, 0, 1], [-1, 0, 0]].each_with_index do |normal, k|
      j = (k + 1) % profile.size
      faces << face(normal, [near[k], far[k], far[j], near[j]])
    end
    edges_on(faces, ring_sides(near) + ring_sides(far) + near.zip(far))
  end
end

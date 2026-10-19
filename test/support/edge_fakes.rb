# test/support/edge_fakes.rb
# Duck-typed edges for the pure feature-edge selection in Handlers::Operations
# (seam_edge?, curved_rim_edges, select_feature_edges), reusable by any test
# that feeds a body's edges to the edge ops. They answer exactly what that
# code reads:
#   Edge#faces, #vertices, #other_vertex, #start, #end
#   Vertex#position, Face#normal, Point3d#-, Vector3d#angle_between
#
# Vertices, faces and edges are plain objects, NOT Structs: in SketchUp an
# entity is its identity, so two vertices at the same position are still two
# vertices. Struct equality is by value and would merge them.
#
# Constructors: FakeVertex.new(position), FakeFace.new(normal),
# FakeEdge.new(start_vertex, end_vertex, faces).
#
# The Sketchup stubs are guarded: other test files define their own empty
# Sketchup::Edge / Sketchup::Face, and under run_all every file loads before
# any test runs, so this file must not depend on load order. FakeEdge and
# FakeFace subclass them so that entities.grep(Sketchup::Edge) sees the fakes.
module Sketchup
  class Edge; end unless defined?(Edge)
  class Face; end unless defined?(Face)
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
      cx = y * other.z - z * other.y
      cy = z * other.x - x * other.z
      cz = x * other.y - y * other.x
      dot = x * other.x + y * other.y + z * other.z
      Math.atan2(Math.sqrt(cx * cx + cy * cy + cz * cz), dot)
    end
  end

  # Geom::Point3d stand-in: Point3d - Point3d is a Vector3d.
  FakePt = Struct.new(:x, :y, :z) do
    def -(other)
      FakeVec.new(x - other.x, y - other.y, z - other.z)
    end
  end

  class FakeVertex
    attr_reader :position

    def initialize(position)
      @position = position
    end
  end

  class FakeFace < Sketchup::Face
    attr_reader :normal

    def initialize(normal)
      @normal = normal
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
  end

  # The 3n edges of a regular n-gon prism (radius RADIUS, from z0 up to z1)
  # with real normals: caps (0, 0, -1) and (0, 0, 1), each side face facing
  # outward at its mid-angle. Listed like a default SketchUp cylinder: the
  # bottom rim (n edges), the top rim (n edges), then the n vertical edges,
  # so the seams of prism(24) sit at indices 48..71. Every call builds its own
  # vertices and faces, so two prisms never share an entity.
  #
  # Dihedral angles: rims 90 degrees, vertical edges 360 / n degrees.
  def self.prism(n, z0: 0, z1: 100)
    raise ArgumentError, "a prism needs at least 3 sides, got #{n}" if n < 3

    step = 2 * Math::PI / n
    ring = lambda do |z|
      Array.new(n) do |i|
        FakeVertex.new(FakePt.new(RADIUS * Math.cos(i * step), RADIUS * Math.sin(i * step), z))
      end
    end
    bottom = ring.call(z0)
    top    = ring.call(z1)

    cap_bottom = FakeFace.new(FakeVec.new(0.0, 0.0, -1.0))
    cap_top    = FakeFace.new(FakeVec.new(0.0, 0.0, 1.0))
    sides = Array.new(n) do |i|
      mid = (i + 0.5) * step
      FakeFace.new(FakeVec.new(Math.cos(mid), Math.sin(mid), 0.0))
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
end

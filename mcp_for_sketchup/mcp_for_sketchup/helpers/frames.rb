# mcp_for_sketchup/mcp_for_sketchup/helpers/frames.rb
module MCPforSketchUp
  module Helpers
    # Block A (M-03): world coordinates at the MCP boundary.
    #
    # An entity's bounds are in its parent's frame: the model's (the world)
    # at the top level, a definition's inside a group or component. The walk
    # in `placement` multiplies the transformations of the instances above
    # the entity into the matrix that maps that frame to the world. While
    # the user has a group open for editing, SketchUp reports the instances
    # on the open path with an identity transformation and their contents in
    # world coordinates; the walk gives the same answer in both states, so
    # edit contexts need no special case (live, SketchUp 2027).
    #
    # Matrices are 16 Floats in column-major order, exactly as
    # Geom::Transformation#to_a gives them: the translation is in elements
    # 12..14. The pure functions below take and return such arrays and
    # [x, y, z] points; they are unit-agnostic and are called with inches.
    module Frames
      SE = MCPforSketchUp::Core::StructuredError

      IDENTITY = [1.0, 0.0, 0.0, 0.0,
                  0.0, 1.0, 0.0, 0.0,
                  0.0, 0.0, 1.0, 0.0,
                  0.0, 0.0, 0.0, 1.0].freeze

      # The walk stops here: SketchUp models never nest this deep, and a
      # definition placed inside itself must not hang SketchUp's UI thread.
      MAX_DEPTH = 64

      # matrix: the frame of entity.bounds → world. depth: the definitions
      # between the entity and the model. shared: nil, or {label:, copies:}
      # for the first definition on the way up with more than one instance.
      Placement = Struct.new(:matrix, :depth, :shared)

      # ===== pure matrix math =================================================

      # a·b: b applies first, then a.
      def self.multiply(a, b)
        out = Array.new(16, 0.0)
        4.times do |col|
          4.times do |row|
            sum = 0.0
            4.times { |k| sum += a[k * 4 + row] * b[col * 4 + k] }
            out[col * 4 + row] = sum
          end
        end
        out
      end

      def self.apply(m, point)
        x, y, z = point
        [m[0] * x + m[4] * y + m[8] * z + m[12],
         m[1] * x + m[5] * y + m[9] * z + m[13],
         m[2] * x + m[6] * y + m[10] * z + m[14]]
      end

      # Of the 3×3 linear part: the factor by which the matrix scales volumes
      # (negative when it mirrors).
      def self.determinant(m)
        dot(m[0, 3], cross(m[4, 3], m[8, 3]))
      end

      # The inverse of an affine matrix. The rows of the inverse linear part
      # are the cross products of its columns over the determinant.
      def self.inverse(m)
        det = determinant(m)
        if det.abs <= 1e-12
          raise SE.new(-32603,
            "a transformation of the entity or of a group or component holding it cannot be " \
            "inverted (a scale of 0 along some axis); give it a non-zero scale and try again")
        end
        c0 = m[0, 3]
        c1 = m[4, 3]
        c2 = m[8, 3]
        rows = [cross(c1, c2), cross(c2, c0), cross(c0, c1)].map { |r| r.map { |v| v / det } }
        t = m[12, 3]
        out = Array.new(16, 0.0)
        rows.each_with_index do |r, i|
          3.times { |j| out[j * 4 + i] = r[j] }
          out[12 + i] = -dot(r, t)
        end
        out[15] = 1.0
        out
      end

      def self.identity?(m, tol = 1e-12)
        m.each_with_index.all? { |v, i| (v - IDENTITY[i]).abs <= tol }
      end

      # Floats; divided by element 15 (w) when it is not 1. SketchUp 2027
      # returns w = 1 even for a uniform scaling, but a uniform scale held in
      # w is what older SketchUp versions stored.
      def self.normalize(values)
        floats = values.map(&:to_f)
        w = floats[15]
        return floats if w == 1.0 || w.zero?
        floats.map { |v| v / w }
      end

      def self.translation(dx, dy, dz)
        [1.0, 0.0, 0.0, 0.0,
         0.0, 1.0, 0.0, 0.0,
         0.0, 0.0, 1.0, 0.0,
         dx.to_f, dy.to_f, dz.to_f, 1.0]
      end

      # A right-handed rotation by `degrees` about the world axis `axis`
      # (0, 1, 2 for X, Y, Z) through `center`, as
      # Geom::Transformation.rotation turns.
      def self.rotation(center, axis, degrees)
        rad = degrees * Math::PI / 180.0
        c = Math.cos(rad)
        s = Math.sin(rad)
        linear =
          case axis
          when 0 then [1.0, 0.0, 0.0, 0.0, 0.0, c, s, 0.0, 0.0, -s, c, 0.0]
          when 1 then [c, 0.0, -s, 0.0, 0.0, 1.0, 0.0, 0.0, s, 0.0, c, 0.0]
          when 2 then [c, s, 0.0, 0.0, -s, c, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]
          else raise ArgumentError, "axis must be 0, 1 or 2, got #{axis.inspect}"
          end
        about(center, linear + [0.0, 0.0, 0.0, 1.0])
      end

      # Scaling along the world axes about `center`.
      def self.scaling(center, sx, sy, sz)
        about(center, [sx.to_f, 0.0, 0.0, 0.0,
                       0.0, sy.to_f, 0.0, 0.0,
                       0.0, 0.0, sz.to_f, 0.0,
                       0.0, 0.0, 0.0, 1.0])
      end

      # inverse(parent)·world·parent: the transformation that, applied in the
      # parent's frame, does `world` in the world.
      def self.conjugate(world, parent)
        multiply(inverse(parent), multiply(world, parent))
      end

      # The box of the eight corners of `bounds` (anything with min and max
      # points that answer x, y, z) mapped through `m`: [[min], [max]], as
      # Floats. A SketchUp Length compares within SketchUp's tolerance; the
      # math wants plain numbers.
      def self.world_box(bounds, m)
        lo = [bounds.min.x.to_f, bounds.min.y.to_f, bounds.min.z.to_f]
        hi = [bounds.max.x.to_f, bounds.max.y.to_f, bounds.max.z.to_f]
        points = [lo[0], hi[0]].product([lo[1], hi[1]], [lo[2], hi[2]]).map { |corner| apply(m, corner) }
        [(0..2).map { |a| points.map { |p| p[a] }.min },
         (0..2).map { |a| points.map { |p| p[a] }.max }]
      end

      def self.center(box)
        (0..2).map { |a| (box[0][a] + box[1][a]) / 2.0 }
      end

      def self.about(center, linear)
        cx, cy, cz = center
        multiply(translation(cx, cy, cz), multiply(linear, translation(-cx, -cy, -cz)))
      end

      def self.cross(a, b)
        [a[1] * b[2] - a[2] * b[1],
         a[2] * b[0] - a[0] * b[2],
         a[0] * b[1] - a[1] * b[0]]
      end

      def self.dot(a, b)
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
      end

      # ===== SketchUp ==========================================================

      def self.matrix_of(transformation)
        normalize(transformation.to_a)
      end

      # The one place that builds a Geom::Transformation from a matrix.
      def self.transformation(m)
        Geom::Transformation.new(m)
      end

      # The walk: from entity.parent up to the model. A definition with no
      # instances is not placed in the model and ends the walk. When a
      # definition has several instances the first one is followed (the
      # first placement), and the entity is shared: the edit would change the
      # contents of every copy. Its copies are the placements of the
      # definition that holds the entity, through the whole hierarchy
      # (count_used_instances, live on SketchUp 2027).
      def self.placement(entity)
        matrix = IDENTITY
        depth = 0
        shared = nil
        holding = entity.parent
        parent = holding
        while parent.is_a?(Sketchup::ComponentDefinition)
          instances = parent.instances
          break if instances.empty?
          if depth >= MAX_DEPTH
            raise SE.new(-32603,
              "the entity is nested more than #{MAX_DEPTH} groups or components deep; " \
              "its place in the model cannot be worked out")
          end
          if shared.nil? && instances.length > 1
            shared = { label: label_of(parent), copies: holding.count_used_instances }
          end
          instance = instances.first
          matrix = multiply(matrix_of(instance.transformation), matrix)
          depth += 1
          parent = instance.parent
        end
        Placement.new(matrix, depth, shared)
      end

      # How a refusal names a definition: a component by its name; a group
      # by its (first) instance's name, since group definitions are named
      # "Group#N" by SketchUp.
      def self.label_of(definition)
        return "component '#{definition.name}'" unless definition.group?
        name = definition.instances.first&.name.to_s
        name.empty? ? "an unnamed group" : "group '#{name}'"
      end

      def self.shared?(definition)
        definition.instances.length > 1
      end

      # A definition with several instances can still count one placement in
      # the model: its other instances then sit in definitions that are not
      # placed.
      def self.copies_text(count)
        count > 1 ? "placed #{count} times in the model" : "shared with a copy that is not placed in the model"
      end

      # -32602 for an entity inside a shared definition; the placement
      # otherwise, so the caller can use its matrix.
      def self.require_unshared!(entity, what)
        placement = placement(entity)
        shared = placement.shared
        return placement if shared.nil?
        raise SE.new(-32602,
          "#{what} is inside #{shared[:label]}, which is #{copies_text(shared[:copies])}, so changing " \
          "it would change every copy. To change all copies, edit the definition through eval_ruby; " \
          "to change one copy, make it unique first (Make Unique in SketchUp, or make_unique through " \
          "eval_ruby), then use the new ids of the entities inside it (list_components with " \
          "recursive=true)")
      end

      # The world box of `bounds` through `m`, in mm; nil for empty bounds
      # (T-55: SketchUp's inverted sentinel must not leak as ±2.54e31 mm).
      def self.bbox_mm(bounds, m)
        return nil if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bounds)
        lo, hi = world_box(bounds, m)
        {
          "min" => lo.map { |v| MCPforSketchUp::Helpers::Units.inch_to_mm(v) },
          "max" => hi.map { |v| MCPforSketchUp::Helpers::Units.inch_to_mm(v) }
        }
      end

      def self.world_bbox_mm(entity)
        bbox_mm(entity.bounds, placement(entity).matrix)
      end

      # The groups and components open for editing, outermost first.
      def self.editing(model)
        (model.active_path || []).map do |instance|
          {
            "id"     => instance.entityID,
            "name"   => MCPforSketchUp::Helpers::Entities.display_name(instance),
            "shared" => shared?(instance.definition)
          }
        end
      end

      # create_component builds in the open group, as SketchUp's own tools do;
      # in a shared one the new object would appear in every copy (spec §6.1).
      def self.require_open_path_unshared!(model)
        instance = (model.active_path || []).reverse.find { |i| shared?(i.definition) }
        return nil if instance.nil?
        definition = instance.definition
        raise SE.new(-32602,
          "#{label_of(definition)} is open for editing and is " \
          "#{copies_text(definition.count_used_instances)}, so a new object would appear in every " \
          "copy. Close it, or make the open copy unique first (Make Unique in SketchUp, or " \
          "make_unique through eval_ruby), then retry")
      end
    end
  end
end

# su_mcp/su_mcp/helpers/geometry.rb
module SU_MCP
  module Helpers
    module Geometry
      # Helpers operate in SketchUp internal coordinates (inches). Callers do
      # mm→inch conversion via Helpers::Units before invoking these.

      # Box in SketchUp internal coordinates (inches). Always extrudes UP by +Z
      # regardless of the auto-selected face.normal direction. See CLAUDE.md
      # «make_box» note for context.
      def self.make_box(entities, x, y, z, w, d, h)
        grp = entities.add_group
        face = grp.entities.add_face(
          [x,     y,     z],
          [x + w, y,     z],
          [x + w, y + d, z],
          [x,     y + d, z]
        )
        sign = face.normal.z >= 0 ? 1 : -1
        face.pushpull(sign * h)
        grp
      end

      def self.circle_points(center, radius, segments)
        segments.times.map do |i|
          angle = Math::PI * 2 * i / segments
          [center[0] + radius * Math.cos(angle),
           center[1] + radius * Math.sin(angle),
           center[2]]
        end
      end
    end
  end
end

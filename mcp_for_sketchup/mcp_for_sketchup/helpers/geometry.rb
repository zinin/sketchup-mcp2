# mcp_for_sketchup/mcp_for_sketchup/helpers/geometry.rb
module MCPforSketchUp
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

      # Bounding box that unions only visible top-level entities of the
      # current model — i.e. honors `entity.hidden?` and the visibility
      # of the entity's layer (`Sketchup::Layer#visible?`). Used by the
      # viewport screenshot tool for `view_preset` framing so the camera
      # frames what the user currently sees (consistent with screenshot
      # not unhiding anything; see design §5.2 / §5.6).
      #
      # Returns `model.bounds` (the global bbox of all entities, hidden
      # or not) when nothing is visible — degrade gracefully rather than
      # produce a degenerate camera.
      def self.visible_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |e|
          next if e.respond_to?(:hidden?) && e.hidden?
          if e.respond_to?(:layer)
            layer = e.layer
            next if layer && layer.respond_to?(:visible?) && !layer.visible?
          end
          bb.add(e.bounds) if e.respond_to?(:bounds)
        end
        return model.bounds if bb.empty? || bb.diagonal.to_f <= 0.0
        bb
      end

      # T-55: пустой Geom::BoundingBox SketchUp — «инвертированный» сентинел
      # (min = +1e30 дюймов, max = −1e30 по каждой оси). Проверяем все оси:
      # частичная инверсия — тоже «пусто», одноосевая проверка кодировала бы
      # частный вид сентинела.
      def self.empty_bbox?(bb)
        bb.min.x > bb.max.x || bb.min.y > bb.max.y || bb.min.z > bb.max.z
      end
    end
  end
end

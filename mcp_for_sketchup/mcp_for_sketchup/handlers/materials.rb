# su_mcp/su_mcp/handlers/materials.rb
module MCPforSketchUp
  module Handlers
    module Materials
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities

      NAMED_COLORS = {
        "red"     => [255, 0, 0],
        "green"   => [0, 255, 0],
        "blue"    => [0, 0, 255],
        "yellow"  => [255, 255, 0],
        "cyan"    => [0, 255, 255],
        "turquoise" => [0, 255, 255],
        "magenta" => [255, 0, 255],
        "purple"  => [255, 0, 255],
        "white"   => [255, 255, 255],
        "black"   => [0, 0, 0],
        "brown"   => [139, 69, 19],
        "wood"    => [184, 134, 72],
        "orange"  => [255, 165, 0],
        "gray"    => [128, 128, 128],
        "grey"    => [128, 128, 128]
      }.freeze
      HEX_COLOR_RE = /\A#\h{6}\z/.freeze

      def self.set_material(params)
        id   = V.require_id(params)
        name = V.require_string(params, "material")

        model = E.active_model!
        model.start_operation("Set Material (#{name.capitalize})", true)
        begin
          entity = E.find!(id)
          material = ensure_material(model, name)
          apply_to_entity(entity, material)
          model.commit_operation
          MCPforSketchUp::Handlers::Geometry.describe_entity(entity)
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      def self.ensure_material(model, name)
        existing = model.materials[name]
        return existing if existing
        material = model.materials.add(name)
        material.color = pick_color(name)
        material
      end

      # Resolve a color spec to a Sketchup::Color. Accepts:
      #   - named colors (case-insensitive, see NAMED_COLORS)
      #   - 6-digit hex with leading #, e.g. "#a05030"
      # Anything else raises -32602 so the caller learns instead of getting a
      # silent brown-wood fallback (which used to mask typos like "#XYZ" or
      # 3-/8-char hex).
      def self.pick_color(name)
        named = NAMED_COLORS[name.downcase]
        return Sketchup::Color.new(*named) if named
        if HEX_COLOR_RE.match?(name)
          r = name[1..2].to_i(16)
          g = name[3..4].to_i(16)
          b = name[5..6].to_i(16)
          return Sketchup::Color.new(r, g, b)
        end
        raise Core::StructuredError.new(-32602,
          "invalid color: #{name.inspect} (expected named color or '#rrggbb')")
      end

      # Material is applied only to the DIRECT-CHILD faces of the
      # Group/ComponentInstance. Faces inside nested sub-groups remain
      # untouched. This is fine for primitives created by Geometry.create_*
      # and for the top-level result of boolean ops (all faces are direct
      # children), but callers applying a material to a hand-built complex
      # assembly should walk the children themselves.
      def self.apply_to_entity(entity, material)
        if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          E.entity_collection(entity)
            .grep(Sketchup::Face)
            .each { |face| face.material = material }
        elsif entity.respond_to?(:material=)
          entity.material = material
        end
      end
    end
  end
end

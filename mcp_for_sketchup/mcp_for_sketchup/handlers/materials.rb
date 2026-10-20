# mcp_for_sketchup/mcp_for_sketchup/handlers/materials.rb
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
          require_paintable!(entity, id)
          material = ensure_material(model, name)
          apply_to_entity(entity, material)
          # Describe BEFORE the commit: a failure here must roll the paint
          # back, not leave it in the model behind an error the client will
          # answer with a retry or an undo.
          description = MCPforSketchUp::Handlers::Geometry.describe_entity(entity)
          model.commit_operation
          description
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # What set_material can paint. The Sketchup constants are resolved at
      # call time, so loading this file does not need them.
      def self.paintable?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance) ||
          entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
      end

      # Refuse what takes no paint (a ComponentDefinition, say) instead of
      # committing nothing and reporting a success.
      def self.require_paintable!(entity, id)
        return entity if paintable?(entity)
        raise Core::StructuredError.new(-32602,
          "set_material needs a group, component instance, face or edge; " \
          "entity #{id} is a #{entity.typename}")
      end

      # How a material spec resolves, in this order:
      #   1. a material of the model with this name, used as is. SketchUp's
      #      Materials#[] matches names without regard to case, so an
      #      existing "Red" is used for "red";
      #   2. a named color or "#rrggbb" in any case, found or created under
      #      its lower-case name, so "Red" and "red" are one material;
      #   3. anything else raises -32602 before a material is created.
      def self.ensure_material(model, name)
        existing = model.materials[name]
        return existing if existing

        canonical = canonical_material_name(name)
        unless canonical
          raise Core::StructuredError.new(-32602,
            "invalid color: #{name.inspect} " \
            "(expected an existing material name, a named color or '#rrggbb')")
        end
        existing = model.materials[canonical]
        return existing if existing

        material = model.materials.add(canonical)
        material.color = pick_color(canonical)
        material
      end

      # The name a color spec is stored under: its lower-case form when it is
      # a named color or a 6-digit hex, else nil.
      def self.canonical_material_name(name)
        lowered = name.downcase
        lowered if NAMED_COLORS.key?(lowered) || HEX_COLOR_RE.match?(lowered)
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
      # T-16: mutable_* — покраска одного инстанса не должна красить остальные копии.
      def self.apply_to_entity(entity, material)
        if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          E.mutable_entity_collection(entity)
            .grep(Sketchup::Face)
            .each { |face| face.material = material }
        elsif entity.respond_to?(:material=)
          entity.material = material
        end
      end
    end
  end
end

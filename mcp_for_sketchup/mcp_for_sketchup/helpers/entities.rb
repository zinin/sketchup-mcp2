# mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb
module MCPforSketchUp
  module Helpers
    module Entities
      E = MCPforSketchUp::Core::StructuredError

      def self.active_model!
        m = Sketchup.active_model
        raise E.new(-32603, "no active model") unless m
        m
      end

      def self.find!(id)
        int_id = id.is_a?(Integer) ? id : Integer(id.to_s, 10)
        entity = active_model!.find_entity_by_id(int_id)
        # -32602 (invalid params) — это user-facing «id не существует»,
        # не internal error; Claude может retry с другим id.
        raise E.new(-32602, "entity #{int_id} not found") unless entity
        raise E.new(-32602, "entity #{int_id} is invalid (erased)") unless entity.valid?
        entity
      end

      def self.require_group_or_component!(entity, label = "entity")
        raise E.new(-32602, "#{label} is invalid (erased)") unless entity.valid?
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          raise E.new(-32602,
            "#{label} must be a Group or ComponentInstance, got #{entity.class.name}")
        end
        entity
      end

      def self.entity_collection(group_or_component)
        group_or_component.is_a?(Sketchup::Group) \
          ? group_or_component.entities \
          : group_or_component.definition.entities
      end
    end
  end
end

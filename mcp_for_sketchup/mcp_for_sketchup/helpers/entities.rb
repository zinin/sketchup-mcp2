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

      # T-16: definition.entities у ComponentInstance (и у copy-paste-копий
      # Group — SketchUp шарит definition группы до первого редактирования
      # или make_unique) ШАРИТСЯ между инстансами — мутация через
      # entity_collection красит/режет все копии разом («четыре стула
      # краснеют одним set_material»). Мутирующие хендлеры обязаны ходить
      # сюда: make_unique отвязывает entity в собственную definition (для
      # уже-уникального — дёшево, для объекта без make_unique — no-op).
      # Read-only обходы (list/find/get_component_info) остаются на
      # entity_collection.
      def self.mutable_entity_collection(group_or_component)
        group_or_component.make_unique if group_or_component.respond_to?(:make_unique)
        entity_collection(group_or_component)
      end
    end
  end
end

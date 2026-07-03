# mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb
require "set"

module MCPforSketchUp
  module Handlers
    module Model
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units

      DEFAULT_MAX_DEPTH = 3
      DEFAULT_LIMIT = 50
      LIMIT_MAX     = 500   # верхняя граница limit — зеркало Python Field(le=500)

      # get_component_info reuses find_component_by_id (see below) so a nested
      # entity's bbox is world-correct. That traversal needs a depth bound;
      # this one is deliberately generous (64) — it only limits how deeply
      # nested an entity can be and still resolve via the world-frame path,
      # falling back to describe_component (parent-frame) only beyond it.
      LOOKUP_MAX_DEPTH = 64

      # ===== get_model_info ==================================================

      def self.get_model_info(_params)
        m = E.active_model!
        bb = m.bounds
        {
          "path"        => m.path,
          "title"       => m.title,
          "units"       => "mm",
          "bounding_box_mm" => bbox_mm_or_nil(bb),
          "entity_count" => m.entities.length,
          "layers"       => m.layers.map(&:name)
        }
      end

      # ===== list_components =================================================
      #
      # Recursive traversal is bounded by `max_depth` (default 3) and a
      # path-local seen-definitions set to prevent infinite recursion on
      # self-referencing ComponentInstance trees, while still enumerating
      # children of every distinct instance of a shared definition (e.g.
      # four chairs around a table). Bounds are returned in WORLD coordinates
      # (chain of parent transformations applied) so Claude doesn't have to
      # know about local-space nesting.

      def self.list_components(params)
        recursive = V.optional_bool(params, "recursive", false)
        max_depth = V.optional_int_positive(params, "max_depth", DEFAULT_MAX_DEPTH)
        limit, offset, response_format = pagination_params(params)
        m = E.active_model!
        identity = Geom::Transformation.new
        seen = Set.new
        components = collect_components(m.entities, identity,
                                        recursive: recursive,
                                        depth: 0,
                                        max_depth: max_depth,
                                        seen: seen)
        paginate(components, limit, offset, response_format)
      end

      # parent_t is the accumulated world transformation; bounds in describe
      # use it to project back to world space.
      #
      # `seen` tracks ComponentDefinition IDs that are currently active on the
      # recursion *path* — definitions are added before descending and removed
      # after. This blocks true cycles (a definition that contains itself)
      # without skipping siblings that merely share a definition.
      def self.collect_components(entities, parent_t, recursive:, depth:, max_depth:, seen:)
        out = []
        return out if depth > max_depth
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          out << describe_component(entity, parent_t, depth: depth)
          next unless recursive
          def_id = nil
          if entity.is_a?(Sketchup::ComponentInstance)
            def_id = entity.definition.entityID
            next if seen.include?(def_id)  # path-local cycle guard
            seen.add(def_id)
          end
          begin
            sub = E.entity_collection(entity)
            child_t = parent_t * entity.transformation
            out.concat(collect_components(sub, child_t,
                                          recursive: true,
                                          depth: depth + 1,
                                          max_depth: max_depth,
                                          seen: seen))
          ensure
            seen.delete(def_id) if def_id
          end
        end
        out
      end

      # T-07: тот же DFS, что collect_components (включая path-local cycle
      # guard), но с ранним выходом на первом совпадении id — get_component_info
      # больше не обходит всю модель ради одного entity.
      def self.find_component_by_id(entities, target_id, parent_t, depth:, max_depth:, seen:)
        return nil if depth > max_depth
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          return describe_component(entity, parent_t, depth: depth) if entity.entityID == target_id
          def_id = nil
          if entity.is_a?(Sketchup::ComponentInstance)
            def_id = entity.definition.entityID
            next if seen.include?(def_id)
            seen.add(def_id)
          end
          begin
            found = find_component_by_id(E.entity_collection(entity), target_id,
                                         parent_t * entity.transformation,
                                         depth: depth + 1, max_depth: max_depth,
                                         seen: seen)
            return found if found
          ensure
            seen.delete(def_id) if def_id
          end
        end
        nil
      end

      def self.describe_component(entity, parent_t = Geom::Transformation.new, depth: 0)
        bb = entity.bounds
        if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)  # T-55
          return {
            "id"    => entity.entityID,
            "name"  => entity.name,
            "type"  => entity.is_a?(Sketchup::Group) ? "group" : "component",
            "layer" => entity.layer.name,
            "depth" => depth,
            "bbox_mm" => nil
          }
        end
        # Project local-space bounds corners through parent transformation chain
        # to get world-space bbox. For top-level entities, parent_t = identity,
        # behaviour identical to monolith.
        world_corners = [
          bb.min, bb.max,
          Geom::Point3d.new(bb.min.x, bb.min.y, bb.max.z),
          Geom::Point3d.new(bb.min.x, bb.max.y, bb.min.z),
          Geom::Point3d.new(bb.min.x, bb.max.y, bb.max.z),
          Geom::Point3d.new(bb.max.x, bb.min.y, bb.min.z),
          Geom::Point3d.new(bb.max.x, bb.min.y, bb.max.z),
          Geom::Point3d.new(bb.max.x, bb.max.y, bb.min.z)
        ].map { |p| parent_t * p }
        xs = world_corners.map(&:x); ys = world_corners.map(&:y); zs = world_corners.map(&:z)
        {
          "id"    => entity.entityID,
          "name"  => entity.name,
          "type"  => entity.is_a?(Sketchup::Group) ? "group" : "component",
          "layer" => entity.layer.name,
          "depth" => depth,
          "bbox_mm" => {
            "min" => [U.inch_to_mm(xs.min), U.inch_to_mm(ys.min), U.inch_to_mm(zs.min)],
            "max" => [U.inch_to_mm(xs.max), U.inch_to_mm(ys.max), U.inch_to_mm(zs.max)]
          }
        }
      end

      # T-55: пустые bounds наружу утекали как ±2.54e31 мм и выглядели
      # валидными координатами. Отдаём null.
      def self.bbox_mm_or_nil(bb)
        return nil if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)
        {
          "min" => [U.inch_to_mm(bb.min.x), U.inch_to_mm(bb.min.y), U.inch_to_mm(bb.min.z)],
          "max" => [U.inch_to_mm(bb.max.x), U.inch_to_mm(bb.max.y), U.inch_to_mm(bb.max.z)]
        }
      end

      # T-07: единые параметры и форма пагинации для list/find. Без лимитов
      # рекурсивный обход тяжёлой модели выгружал мегабайты JSON прямо в
      # контекст модели (отказ только на 64 MiB фрейм-капе).
      # P-03 (решение ревью): обход остаётся ПОЛНЫМ (collect + slice) —
      # точный total иначе не получить, а обход всей модели был нормой
      # этого хендлера и до пагинации; цель тикета — размер ОТВЕТА, и она
      # достигнута. Материализация хешей вне страницы — не bottleneck для
      # реальных SketchUp-моделей; traversal-аккумулятор отклонён как
      # сложность без болевой точки.
      def self.pagination_params(params)
        [
          V.optional_int_range(params, "limit", min: 1, max: LIMIT_MAX, default: DEFAULT_LIMIT),
          V.optional_int_nonneg(params, "offset", 0),
          V.optional_enum(params, "response_format", %w[concise detailed], "detailed"),
        ]
      end

      def self.paginate(components, limit, offset, response_format)
        page = components.slice(offset, limit) || []
        if response_format == "concise"
          page = page.map { |c| c.slice("id", "name", "type", "layer", "depth") }
        end
        {
          "components" => page,
          "total"      => components.length,
          "offset"     => offset,
          "truncated"  => offset + page.length < components.length,
        }
      end

      # ===== get_component_info ==============================================
      #
      # Uses find_component_by_id (early-exit DFS, same world-frame math as
      # collect_components) so the bbox is world-correct + depth correct
      # BY CONSTRUCTION (consistent with list_components). The old code called
      # describe_component(entity) with an identity parent_t, which returns
      # bounds in the entity's PARENT frame — correct only for a top-level
      # entity (parent == world), but WRONG (local, not world) for a nested
      # one. Walking from model.entities accumulates the full parent-transform
      # chain, so the returned bbox matches what list_components reports for the
      # same id. Shared-definition entities resolve to the FIRST match (entity
      # IDs are unique per instance, so an exact id match is unambiguous when
      # present). Falls back to describe_component (parent-frame) only if the
      # entity is nested deeper than LOOKUP_MAX_DEPTH. That fallback returns
      # the bbox in the PARENT frame (identity transformation) — bbox precision
      # degrades for entities nested deeper than LOOKUP_MAX_DEPTH; deliberate,
      # depth 64 never occurs in real-world models.

      def self.get_component_info(params)
        id = V.require_id(params)
        entity = E.find!(id)
        E.require_group_or_component!(entity)
        m = E.active_model!
        find_component_by_id(m.entities, entity.entityID, Geom::Transformation.new,
                             depth: 0, max_depth: LOOKUP_MAX_DEPTH, seen: Set.new) ||
          describe_component(entity)
      end

      # ===== find_components =================================================

      def self.find_components(params)
        name_substring = V.optional_string(params, "name")
        layer_name     = V.optional_string(params, "layer")
        type_filter    = V.optional_enum(params, "type", %w[group component])
        max_depth      = V.optional_int_positive(params, "max_depth", DEFAULT_MAX_DEPTH)
        limit, offset, response_format = pagination_params(params)
        m = E.active_model!
        identity = Geom::Transformation.new
        seen = Set.new
        all = collect_components(m.entities, identity,
                                 recursive: true,
                                 depth: 0,
                                 max_depth: max_depth,
                                 seen: seen)
        # T-18: case-insensitive — «table» находит «Table Leg»
        needle = name_substring&.downcase
        results = all.select do |c|
          (needle.nil? || c["name"].downcase.include?(needle)) &&
            (layer_name.nil? || c["layer"] == layer_name) &&
            (type_filter.nil? || c["type"] == type_filter)
        end
        paginate(results, limit, offset, response_format)
      end

      # ===== list_layers =====================================================

      def self.list_layers(_params)
        layers = E.active_model!.layers.map do |l|
          {
            "name"    => l.name,
            "visible" => l.visible?,
            "color"   => l.color.to_s,
            "id"      => l.entityID
          }
        end
        { "layers" => layers }
      end

      # ===== create_layer ====================================================

      def self.create_layer(params)
        name = V.require_string(params, "name")
        m = E.active_model!
        m.start_operation("Create Layer (#{name})", true)
        begin
          layer = m.layers.add(name)
          m.commit_operation
          { "id" => layer.entityID, "name" => layer.name, "visible" => layer.visible? }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(m)
          raise
        end
      end

      # ===== undo ============================================================
      #
      # SketchUp's Ruby API has no Model#undo. Programmatic undo dispatches the
      # editUndo action via Sketchup.send_action — this triggers the same code
      # path as Edit → Undo in the menu, popping one entry off the undo stack
      # built by start_operation/commit_operation.

      def self.undo(_params)
        E.active_model!  # ensure a model is active; raises if not
        Sketchup.send_action("editUndo:")
        { "ok" => true }
      end

      # ===== get_selection (migrated from monolith) ==========================
      #
      # Returns full {id, name, type, bbox_mm} so Claude can re-locate entities
      # by bounding-box if their IDs become stale after destructive ops.

      def self.get_selection(_params)
        selection = E.active_model!.selection
        identity = Geom::Transformation.new
        entities = selection.map do |entity|
          if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            describe_component(entity, identity)
          else
            { "id" => entity.entityID, "type" => entity.typename.downcase }
          end
        end
        { "entities" => entities }
      end
    end
  end
end

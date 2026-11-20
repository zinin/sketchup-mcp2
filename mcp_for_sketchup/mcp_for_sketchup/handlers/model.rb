# mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb
require "set"

module MCPforSketchUp
  module Handlers
    module Model
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units
      O = MCPforSketchUp::Helpers::Operation
      F = MCPforSketchUp::Helpers::Frames

      DEFAULT_MAX_DEPTH = 3
      DEFAULT_LIMIT = 50
      LIMIT_MAX     = 500   # верхняя граница limit — зеркало Python Field(le=500)

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
          "layers"       => m.layers.map(&:name),
          # The groups and components open for editing, outermost first:
          # create_component builds in the last one, and refuses while any of
          # them is shared (Frames.require_open_path_unshared!).
          "editing"      => F.editing(m)
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
      # know about local-space nesting. Every row carries `shared`: true for
      # the contents of a definition placed more than once, which the
      # mutating tools refuse to edit; a component row also carries its
      # `definition` name.

      def self.list_components(params)
        recursive = V.optional_bool(params, "recursive", false)
        max_depth = V.optional_int_range(params, "max_depth", min: 1, max: 10, default: DEFAULT_MAX_DEPTH)
        limit, offset, response_format = pagination_params(params)
        m = E.active_model!
        seen = Set.new
        components = collect_components(m.entities, F::IDENTITY,
                                        recursive: recursive,
                                        depth: 0,
                                        max_depth: max_depth,
                                        seen: seen)
        paginate(components, limit, offset, response_format)
      end

      # parent_matrix is the accumulated world matrix (Helpers::Frames);
      # describe_component maps the bounds through it to world space.
      # `shared` is true below a definition with more than one instance;
      # `shared_of` remembers that per definition for the whole traversal, so
      # a component placed N times costs one look at its instances, not N
      # (each look copies all of them).
      #
      # `seen` tracks ComponentDefinition IDs that are currently active on the
      # recursion *path* — definitions are added before descending and removed
      # after. This blocks true cycles (a definition that contains itself)
      # without skipping siblings that merely share a definition.
      def self.collect_components(entities, parent_matrix, recursive:, depth:, max_depth:, seen:, shared: false,
                                  shared_of: {})
        out = []
        return out if depth > max_depth
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          out << describe_component(entity, parent_matrix, depth: depth, shared: shared)
          next unless recursive
          def_id = nil
          if entity.is_a?(Sketchup::ComponentInstance)
            def_id = entity.definition.entityID
            next if seen.include?(def_id)  # path-local cycle guard
            seen.add(def_id)
          end
          begin
            sub = E.entity_collection(entity)
            child_matrix = F.multiply(parent_matrix, F.matrix_of(entity.transformation))
            definition = entity.definition
            shared_of[definition] = F.shared?(definition) unless shared_of.key?(definition)
            out.concat(collect_components(sub, child_matrix,
                                          recursive: true,
                                          depth: depth + 1,
                                          max_depth: max_depth,
                                          seen: seen,
                                          shared: shared || shared_of[definition],
                                          shared_of: shared_of))
          ensure
            seen.delete(def_id) if def_id
          end
        end
        out
      end

      # One row: {id, name, type, layer, depth, shared, bbox_mm}, plus
      # `definition` (the definition's name, which the Outliner shows for an
      # unnamed instance) for a component instance; a group's definition is
      # auto-named "Group#N" and is left out. bbox_mm is the entity's world
      # box (Frames.entity_box through parent_matrix) in mm, and is null for
      # an entity without geometry (T-55).
      def self.describe_component(entity, parent_matrix = F::IDENTITY, depth: 0, shared: false)
        row = {
          "id"     => entity.entityID,
          "name"   => entity.name,
          "type"   => entity.is_a?(Sketchup::Group) ? "group" : "component",
          "layer"  => entity.layer.name,
          "depth"  => depth,
          "shared" => shared
        }
        row["definition"] = entity.definition.name if entity.is_a?(Sketchup::ComponentInstance)
        row["bbox_mm"] = F.entity_bbox_mm(entity, parent_matrix)
        row
      end

      # The row of one entity, wherever it is: the walk up its parents gives
      # the world matrix, the depth and whether it is shared (for a shared
      # entity, the first placement's box).
      def self.describe_placed(entity)
        placement = F.placement(entity)
        describe_component(entity, placement.matrix, depth: placement.depth, shared: !placement.shared.nil?)
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
          page = page.map { |c| c.slice("id", "name", "type", "layer", "depth", "shared", "definition") }
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
      # M-19 (part): walks up from the entity (Frames.placement) instead of
      # searching from the model root, so the box is world and the depth is
      # right however deep the entity sits, and in every edit state (spec §3).
      # An entity inside a definition placed more than once reports its first
      # placement with "shared" => true; list_components lists every placement.

      def self.get_component_info(params)
        id = V.require_id(params)
        entity = E.find!(id)
        E.require_group_or_component!(entity)
        describe_placed(entity)
      end

      # ===== find_components =================================================

      def self.find_components(params)
        name_substring = V.optional_string(params, "name")
        layer_name     = V.optional_string(params, "layer")
        type_filter    = V.optional_enum(params, "type", %w[group component])
        max_depth      = V.optional_int_range(params, "max_depth", min: 1, max: 10, default: DEFAULT_MAX_DEPTH)
        limit, offset, response_format = pagination_params(params)
        m = E.active_model!
        seen = Set.new
        all = collect_components(m.entities, F::IDENTITY,
                                 recursive: true,
                                 depth: 0,
                                 max_depth: max_depth,
                                 seen: seen)
        # T-18: case-insensitive — «table» находит «Table Leg». M-17: у
        # экземпляра компонента совпадает и имя определения — так Outliner
        # называет компоненты из 3D Warehouse и импорта; определения групп
        # («Group#N») в строках нет, они не совпадают.
        needle = name_substring&.downcase
        results = all.select do |c|
          (needle.nil? || c["name"].to_s.downcase.include?(needle) ||
            c["definition"].to_s.downcase.include?(needle)) &&
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
        O.run(m, "Create Layer (#{name})") do
          layer = m.layers.add(name)
          { "id" => layer.entityID, "name" => layer.name, "visible" => layer.visible? }
        end
      end

      # ===== undo ============================================================
      #
      # SketchUp's Ruby API has no Model#undo. Programmatic undo dispatches the
      # editUndo action via Sketchup.send_action — this triggers the same code
      # path as Edit → Undo in the menu, popping one entry off the undo stack
      # built by the handlers' operations (Helpers::Operation.run).

      def self.undo(_params)
        E.active_model!  # ensure a model is active; raises if not
        Sketchup.send_action("editUndo:")
        { "ok" => true }
      end

      # ===== get_selection (migrated from monolith) ==========================
      #
      # Returns full {id, name, type, bbox_mm} so Claude can re-locate entities
      # by bounding-box if their IDs become stale after destructive ops. A
      # group or component gets the same row as get_component_info (world box,
      # depth, shared); the selection lives in the open edit context, so the
      # walk up its parents is what makes its box world.

      def self.get_selection(_params)
        selection = E.active_model!.selection
        entities = selection.map do |entity|
          if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            describe_placed(entity)
          else
            { "id" => entity.entityID, "type" => entity.typename.downcase }
          end
        end
        { "entities" => entities }
      end
    end
  end
end

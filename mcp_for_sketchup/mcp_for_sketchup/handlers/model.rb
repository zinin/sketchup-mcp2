# mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb
require "set"

module MCPforSketchUp
  module Handlers
    module Model
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units

      DEFAULT_MAX_DEPTH = 3

      # ===== get_model_info ==================================================

      def self.get_model_info(_params)
        m = E.active_model!
        bb = m.bounds
        {
          "path"        => m.path,
          "title"       => m.title,
          "units"       => "mm",
          "bounding_box_mm" => {
            "min" => [U.inch_to_mm(bb.min.x), U.inch_to_mm(bb.min.y), U.inch_to_mm(bb.min.z)],
            "max" => [U.inch_to_mm(bb.max.x), U.inch_to_mm(bb.max.y), U.inch_to_mm(bb.max.z)]
          },
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
        recursive = params.fetch("recursive", false)
        max_depth = params.fetch("max_depth", DEFAULT_MAX_DEPTH)
        m = E.active_model!
        identity = Geom::Transformation.new
        seen = Set.new
        components = collect_components(m.entities, identity,
                                        recursive: recursive,
                                        depth: 0,
                                        max_depth: max_depth,
                                        seen: seen)
        { "components" => components }
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

      def self.describe_component(entity, parent_t = Geom::Transformation.new, depth: 0)
        bb = entity.bounds
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

      # ===== get_component_info ==============================================

      def self.get_component_info(params)
        id = V.require_id(params)
        entity = E.find!(id)
        E.require_group_or_component!(entity)
        describe_component(entity)
      end

      # ===== find_components =================================================

      def self.find_components(params)
        name_substring = params["name"]
        layer_name     = params["layer"]
        type_filter    = params["type"]  # "group" | "component" | nil
        max_depth      = params.fetch("max_depth", DEFAULT_MAX_DEPTH)
        m = E.active_model!
        identity = Geom::Transformation.new
        seen = Set.new
        all = collect_components(m.entities, identity,
                                 recursive: true,
                                 depth: 0,
                                 max_depth: max_depth,
                                 seen: seen)
        results = all.select do |c|
          (name_substring.nil? || c["name"].include?(name_substring)) &&
            (layer_name.nil? || c["layer"] == layer_name) &&
            (type_filter.nil? || c["type"] == type_filter)
        end
        { "components" => results }
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

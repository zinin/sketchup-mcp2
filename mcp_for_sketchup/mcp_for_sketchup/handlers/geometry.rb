# mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb
module MCPforSketchUp
  module Handlers
    module Geometry
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      G = MCPforSketchUp::Helpers::Geometry
      U = MCPforSketchUp::Helpers::Units

      # Wrap abort_operation so its own potential exception (NoMethodError on
      # older SU, "no operation active" if double-abort) never shadows the
      # original handler exception.
      def self.safe_abort(model)
        model.abort_operation if model.respond_to?(:abort_operation)
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log("DEBUG",
          "Geometry.safe_abort: model.abort_operation raised: " \
          "#{e.class}: #{e.message}")
      end

      def self.create_component(params)
        type = V.require_enum(params, "type", %w[cube cylinder cone sphere])
        # mm → inches for SketchUp internal API
        pos_mm  = V.optional_coords3(params, "position") || [0, 0, 0]
        dims_mm = V.require_dimensions3(params, "dimensions")
        pos  = pos_mm.map  { |v| U.mm_to_inch(v) }
        dims = dims_mm.map { |v| U.mm_to_inch(v) }
        segments = V.optional_int_positive(params, "segments", default_segments_for(type))
        # T-54: опциональное имя группы. Без него все созданные группы
        # безымянны — find_components(name=...) бессилен, а модель не может
        # назвать то, что строит, иначе как через eval_ruby.
        name = params.key?("name") ? V.require_string(params, "name") : nil

        model = E.active_model!
        model.start_operation("Create Component (#{type.capitalize})", true)
        begin
          group = case type
                  when "cube"     then build_cube(model.active_entities, pos, dims)
                  when "cylinder" then build_cylinder(model.active_entities, pos, dims, segments)
                  when "cone"     then build_cone(model.active_entities, pos, dims, segments)
                  when "sphere"   then build_sphere(model.active_entities, pos, dims, segments)
                  end
          group.name = name if name
          model.commit_operation
          describe_entity(group)
        rescue StandardError
          safe_abort(model)
          raise
        end
      end

      # Returns {id, name, type, bbox_mm} so Claude can re-locate after destructive ops.
      # bbox_mm == nil, если у entity пустые bounds (T-55: инвертированный
      # сентинел SketchUp ±1e30" не должен утекать как ±2.54e31 мм).
      def self.describe_entity(entity)
        bb = entity.bounds
        bbox_mm =
          if MCPforSketchUp::Helpers::Geometry.empty_bbox?(bb)
            nil
          else
            {
              "min" => [U.inch_to_mm(bb.min.x), U.inch_to_mm(bb.min.y), U.inch_to_mm(bb.min.z)],
              "max" => [U.inch_to_mm(bb.max.x), U.inch_to_mm(bb.max.y), U.inch_to_mm(bb.max.z)]
            }
          end
        {
          "id"   => entity.entityID,
          "name" => entity.name,
          "type" => entity.is_a?(Sketchup::Group) ? "group" : "component",
          "bbox_mm" => bbox_mm
        }
      end

      def self.delete_component(params)
        id = V.require_id(params)
        model = E.active_model!
        model.start_operation("Delete Component", true)
        begin
          entity = E.find!(id)
          entity.erase!
          model.commit_operation
          { "ok" => true }
        rescue StandardError
          safe_abort(model)
          raise
        end
      end

      # NOTE: transform_component on a ComponentInstance modifies ONLY the
      # selected instance (its transformation matrix), not the underlying
      # ComponentDefinition. Other instances of the same definition are
      # unchanged. To modify the definition, use eval_ruby.
      #
      # `position` — АБСОЛЮТНАЯ цель (T-04, решение 2026-07-02): entity
      # переносится так, чтобы минимальный угол его bbox оказался ровно в
      # заданной точке (тот же якорь, что у create_component.position).
      # rotation/scale остаются относительными, вокруг центра bbox.
      # Порядок применения: rotation → scale → position (ПОСЛЕДНЕЙ, и он
      # намеренно не совпадает с порядком аргументов) — дельта берётся от
      # пост-трансформационного bounds.min, итоговый bbox-min равен цели
      # даже в комбинированных вызовах (ревью iter-1, CRIT-5).
      def self.transform_component(params)
        id = V.require_id(params)
        # position/scale in mm (rotation in degrees — not a size)
        position_mm = V.optional_coords3(params, "position")
        rotation    = V.optional_coords3(params, "rotation")
        scale       = V.optional_coords3(params, "scale")
        position    = position_mm&.map { |v| U.mm_to_inch(v) }

        model = E.active_model!
        model.start_operation("Transform Component", true)
        begin
          entity = E.find!(id)
          if rotation
            apply_rotation(entity, rotation)
          end
          if scale
            center = entity.bounds.center
            entity.transform!(Geom::Transformation.scaling(center, scale[0], scale[1], scale[2]))
          end
          if position
            delta = position_delta(entity.bounds.min, position)
            entity.transform!(Geom::Transformation.translation(
              Geom::Point3d.new(delta[0], delta[1], delta[2])))
          end
          model.commit_operation
          describe_entity(entity)
        rescue StandardError
          safe_abort(model)
          raise
        end
      end

      # ----- private builders ----------------------------------------------

      # Pure math (юнит-тестится без SketchUp): вектор переноса, доставляющий
      # bbox-min `current_min` в точку `target`. Оба аргумента — в дюймах.
      def self.position_delta(current_min, target)
        [target[0] - current_min.x,
         target[1] - current_min.y,
         target[2] - current_min.z]
      end

      def self.default_segments_for(type)
        case type
        when "cylinder", "cone" then 24
        when "sphere"           then 16
        else nil
        end
      end

      def self.build_cube(entities, pos, dims)
        G.make_box(entities, pos[0], pos[1], pos[2], dims[0], dims[1], dims[2])
      end

      def self.build_cylinder(entities, pos, dims, segments)
        radius = dims[0] / 2.0
        height = dims[2]
        center = [pos[0] + radius, pos[1] + radius, pos[2]]
        group = entities.add_group
        face = group.entities.add_face(G.circle_points(center, radius, segments))
        sign = face.normal.z >= 0 ? 1 : -1
        face.pushpull(sign * height)
        group
      end

      def self.build_cone(entities, pos, dims, segments)
        radius = dims[0] / 2.0
        height = dims[2]
        center = [pos[0] + radius, pos[1] + radius, pos[2]]
        apex   = [center[0], center[1], center[2] + height]
        group = entities.add_group
        circle = G.circle_points(center, radius, segments)
        group.entities.add_face(circle)
        (0...segments).each do |i|
          j = (i + 1) % segments
          group.entities.add_face(circle[i], circle[j], apex)
        end
        group
      end

      def self.build_sphere(entities, pos, dims, segments)
        # segments 1-2 молча дают вырожденную геометрию (нет ни одного
        # полноценного кольца) — отклоняем как invalid params.
        raise MCPforSketchUp::Core::StructuredError.new(-32602, "segments must be >= 3 for spheres") if segments < 3
        radius = dims[0] / 2.0
        center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
        group = entities.add_group
        # UV-sphere: latitude × longitude grid
        points = []
        (0..segments).each do |lat_i|
          lat = Math::PI * lat_i / segments
          (0..segments).each do |lon_i|
            lon = 2 * Math::PI * lon_i / segments
            points << [
              center[0] + radius * Math.sin(lat) * Math.cos(lon),
              center[1] + radius * Math.sin(lat) * Math.sin(lon),
              center[2] + radius * Math.cos(lat)
            ]
          end
        end
        (0...segments).each do |lat_i|
          (0...segments).each do |lon_i|
            i1 = lat_i * (segments + 1) + lon_i
            i2 = i1 + 1
            i3 = i1 + segments + 1
            i4 = i3 + 1
            begin
              if lat_i == 0
                # Северная полярная полоса: p1 и p2 — обе копии полюса
                # (sin 0 = 0) ⇒ квад вырожден. Явный треугольник
                # полюс → две точки первого кольца. Deep-research T-02.
                group.entities.add_face(points[i1], points[i4], points[i3])
              elsif lat_i == segments - 1
                # Южная полоса: p3/p4 — копии южного полюса (sin π ≈ 1e-16).
                group.entities.add_face(points[i1], points[i2], points[i4])
              else
                group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
              end
            rescue StandardError => e
              # Последний рубеж: не должен срабатывать для сфер — полюсные
              # вырождения обработаны выше явными треугольниками.
              MCPforSketchUp::Core::Logger.log("DEBUG",
                "build_sphere: skipped degenerate face at pole: #{e.class}: #{e.message}")
            end
          end
        end
        group
      end

      def self.apply_rotation(entity, rot_degrees)
        center = entity.bounds.center
        axes = [Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 1, 0), Geom::Vector3d.new(0, 0, 1)]
        rot_degrees.each_with_index do |deg, i|
          next if deg == 0
          rad = deg * Math::PI / 180
          entity.transform!(Geom::Transformation.rotation(center, axes[i], rad))
        end
      end
    end
  end
end

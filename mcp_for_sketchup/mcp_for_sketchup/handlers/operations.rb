# su_mcp/su_mcp/handlers/operations.rb
module MCPforSketchUp
  module Handlers
    module Operations
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units

      OPS = %w[union difference intersection].freeze

      # ===== boolean_operation (Group-level solid tools) =====================
      #
      # Critical: SketchUp solid-tool methods (`union`/`subtract`/`intersect`/
      # `outer_shell`) live on `Sketchup::Group` and `ComponentInstance`, NOT
      # on `Entities`. They are also DESTRUCTIVE: they erase operands and
      # return a new group. The implementation below makes copies of target
      # and tool so callers' originals survive (controlled by `delete_originals`).
      # The native methods are unreliable on non-manifold geometry — fall back
      # to manifold inputs for predictable results.

      def self.boolean_operation(params)
        operation = V.require_enum(params, "operation", OPS)
        target_id = V.require_id(params, "target_id")
        tool_id   = V.require_id(params, "tool_id")
        # Strict boolean — reject coercion-style truthy strings like "false"
        # (Ruby treats those as truthy, which would silently destroy operands).
        delete_originals = V.optional_bool(params, "delete_originals", false)

        model = E.active_model!
        model.start_operation("Boolean #{operation.capitalize}", true)
        begin
          target = E.find!(target_id)
          tool   = E.find!(tool_id)
          E.require_group_or_component!(target, "target")
          E.require_group_or_component!(tool,   "tool")

          target_copy = duplicate_group(model, target)
          tool_copy   = duplicate_group(model, tool)

          # NB: SketchUp's Group#subtract has REVERSED semantics from naive
          # expectation: A.subtract(B) returns "B - A" (argument minus receiver),
          # not "A - B". Verified empirically: cube.subtract(small_partial) →
          # piece of small OUTSIDE cube; cutter.subtract(cube) → cube minus
          # cutter. To get "target - tool", call tool.subtract(target).
          # union/intersect are commutative, so receiver/argument order is
          # immaterial; only difference is affected.
          result = case operation
                   when "union"        then target_copy.union(tool_copy)
                   when "difference"   then tool_copy.subtract(target_copy)
                   when "intersection" then target_copy.intersect(tool_copy)
                   end
          # Solid tools may return nil on failure (non-manifold inputs).
          if result.nil?
            raise Core::StructuredError.new(-32603,
              "boolean_operation:#{operation} failed (likely non-manifold geometry)")
          end

          if delete_originals
            target.erase! if target.valid?
            tool.erase!   if tool.valid?
          end

          model.commit_operation
          MCPforSketchUp::Handlers::Geometry.describe_entity(result)
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # Faithful copy of a group/component-instance via definition-based instancing.
      # Both Sketchup::Group and ComponentInstance expose a `#definition` returning
      # the underlying ComponentDefinition; instantiating that definition in the
      # source's PARENT entities preserves inner face loops (holes), materials,
      # nested entities, and UV mapping — none of which a manual face-by-face
      # outer-loop copy would carry. SketchUp solid-tools (union/subtract/intersect)
      # accept ComponentInstance operands, so a non-Group return is fine.
      # Cutter must be a SIBLING of the source so subsequent solid ops succeed
      # for nested targets too (parent != model.active_entities).
      def self.duplicate_group(_model, entity)
        entity.parent.entities.add_instance(entity.definition, entity.transformation)
      end

      # ===== chamfer_edges / fillet_edges (sequential subtract per edge) =====
      #
      # Why sequential, not combined:
      #   For a target with N edges meeting at shared corners (e.g. cube),
      #   N profile prisms swept in ONE shared cutter group self-intersect at
      #   the corners. SketchUp's solid tools require BOTH operands to be
      #   manifold; a self-intersecting cutter ⇒ subtract returns nil.
      #   Doing one subtract per edge keeps each cutter a clean swept prism.
      #
      # Why two in-face perpendiculars (perp1, perp2), not n + perp:
      #   The natural chamfer/fillet at a dihedral edge cuts material symmetrically
      #   from BOTH adjacent faces. The profile must lie in the plane perpendicular
      #   to the edge, with one direction along each adjacent face's interior.
      #   Old code used face.normal (which IS in the perpendicular plane only when
      #   the edge already lies in the face) — that puts the profile OUTSIDE the
      #   solid, and subtract finds nothing to remove.
      #
      # NB: dimensions in mm — converted to inches for SketchUp internal API.
      # NB: edges captured before destructive ops; specs live in target.parent
      # frame so cutter (sibling of target) and edge geometry share a frame.

      def self.chamfer_edges(params)
        entity_id = V.require_id(params, "entity_id")
        distance_in = U.mm_to_inch(V.require_positive(params, "distance"))
        edge_indices = params["edge_indices"]
        run_edge_op(entity_id, edge_indices, "Chamfer Edges", distance_in * 2) do |cutter_entities, spec|
          build_chamfer_profile(cutter_entities, spec, distance_in)
        end.merge("edges_chamfered" => last_edges_done, "stats" => last_stats)
      end

      def self.fillet_edges(params)
        entity_id = V.require_id(params, "entity_id")
        radius_in = U.mm_to_inch(V.require_positive(params, "radius"))
        segments  = V.optional_int_positive(params, "segments", 8)
        edge_indices = params["edge_indices"]
        run_edge_op(entity_id, edge_indices, "Fillet Edges", radius_in * 2) do |cutter_entities, spec|
          build_fillet_profile(cutter_entities, spec, radius_in, segments)
        end.merge("edges_filleted" => last_edges_done, "stats" => last_stats)
      end

      # Shared driver for chamfer/fillet. Snapshots edge specs ONCE in parent frame,
      # then for each original spec: re-collects current edges (post any prior
      # subtracts), finds the one that "succeeds" the original (parallel direction
      # + midpoint within tolerance), builds a fresh cutter group as sibling of
      # the CURRENT entity, sweeps the profile, subtracts, and re-binds entity.
      #
      # Why re-collect: after subtract #i, the cube has been modified — corners
      # near the chamfered edge are gone, adjacent edges are trimmed, midpoints
      # shift. The original snapshot's coordinates no longer match the live
      # geometry, so building the next cutter from the original snapshot
      # produces a prism that misaligns with the current solid → subtract nil.
      # Re-collect uses the LIVE edge for the cutter; original snapshot serves
      # only as identity-by-direction-and-line for matching.
      def self.run_edge_op(entity_id, edge_indices, op_name, match_tolerance_in)
        model = E.active_model!
        model.start_operation(op_name, true)
        @_last_edges_done = 0
        @_last_stats = { "attempted" => 0, "skipped_no_match" => 0,
                         "subtract_failed" => 0, "succeeded" => 0 }
        begin
          entity = E.find!(entity_id)
          E.require_group_or_component!(entity, "#{op_name} target")
          target_entities = E.entity_collection(entity)
          edges = target_entities.grep(Sketchup::Edge)
          edges = filter_edges(edges, edge_indices) if edge_indices
          if edges.empty?
            raise Core::StructuredError.new(-32602,
              "no edges to #{op_name} on target_id=#{entity_id} " \
              "(check edge_indices or geometry)")
          end

          # Snapshot original specs (parent-frame) BEFORE any destructive op.
          original_specs = edges.map { |e| edge_spec(e, entity.transformation) }
          @_last_stats["attempted"] = original_specs.length

          # Track the most-recent successful subtract result by ID. Group#subtract
          # may return a proxy that becomes silently stale after subsequent
          # destructive ops in the same start_operation; the cached Integer ID
          # lets us re-resolve a fresh proxy via model.find_entity_by_id below.
          last_result_id = nil

          original_specs.each do |orig|
            # Find the live edge succeeding the original spec in the current
            # (possibly already-modified) entity.
            live_spec = find_current_edge_spec(entity, orig, match_tolerance_in)
            if live_spec.nil?
              @_last_stats["skipped_no_match"] += 1
              next  # original edge was consumed by a prior chamfer face
            end

            cutter = entity.parent.entities.add_group
            profile = yield(cutter.entities, live_spec)
            profile.followme(reconstruct_edge(cutter.entities, live_spec))

            # SketchUp Group#subtract: A.subtract(B) returns "B - A". So to get
            # "entity - cutter" (cube minus chamfer wedge), we call
            # cutter.subtract(entity). See verbose comment in boolean_operation.
            result = cutter.subtract(entity)
            if result.nil?
              # Subtract failed for this edge — clean up the orphan cutter
              # and continue with the remaining edges rather than aborting.
              @_last_stats["subtract_failed"] += 1
              cutter.erase! if cutter.valid?
              next
            end
            # Cache ID immediately while result is fresh; later .entityID on a
            # stale proxy can also throw "reference to deleted DrawingElement".
            last_result_id = result.entityID
            entity = result
            @_last_edges_done += 1
            @_last_stats["succeeded"] += 1
          end

          if @_last_edges_done == 0
            raise Core::StructuredError.new(-32603,
              "#{op_name}: no edges could be cut on target_id=#{entity_id} " \
              "(geometry may be non-manifold)")
          end

          # Re-resolve via model.find_entity_by_id. After a chain of solid-tool
          # subtracts, the local `entity` variable holds a proxy that may be
          # invalid even though entity = result rebound it correctly each
          # iteration; SketchUp's internal indexing of operands inside one
          # start_operation transaction is fragile across many destructive
          # steps. The Integer ID cached at subtract-time is stable; the fresh
          # proxy from find_entity_by_id is safe to read .bounds from.
          # describe_entity is intentionally called BEFORE commit_operation —
          # commit has been observed to invalidate solid-tool result proxies.
          fresh = last_result_id ? model.find_entity_by_id(last_result_id) : nil
          if fresh.nil? || !fresh.valid?
            raise Core::StructuredError.new(-32603,
              "#{op_name}: final entity invalid after subtract chain " \
              "(id=#{last_result_id}, edges_done=#{@_last_edges_done})")
          end
          description = MCPforSketchUp::Handlers::Geometry.describe_entity(fresh)
          model.commit_operation
          description
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      def self.last_edges_done
        @_last_edges_done || 0
      end

      def self.last_stats
        @_last_stats || { "attempted" => 0, "skipped_no_match" => 0,
                          "subtract_failed" => 0, "succeeded" => 0 }
      end

      # Find the current edge in `entity` that succeeds `orig_spec`. Match
      # criteria: parallel direction + midpoint within `tolerance_in`. Returns
      # the spec of that live edge (in parent frame), or nil if no match —
      # meaning the original was consumed by a prior chamfer face.
      def self.find_current_edge_spec(entity, orig_spec, tolerance_in)
        cur_edges = E.entity_collection(entity).grep(Sketchup::Edge)
                     .select { |e| e.faces.length >= 2 }
        return nil if cur_edges.empty?

        orig_dir = orig_spec[:end_pos] - orig_spec[:start_pos]
        return nil if orig_dir.length < 1e-10
        orig_dir.length = 1.0
        orig_mid = midpoint_of(orig_spec[:start_pos], orig_spec[:end_pos])

        xform = entity.transformation
        best, best_dist = nil, Float::INFINITY
        cur_edges.each do |edge|
          cs = xform * edge.start.position
          ce = xform * edge.end.position
          cur_dir = ce - cs
          next if cur_dir.length < 1e-10
          cur_dir.length = 1.0
          next unless cur_dir.parallel?(orig_dir)

          dist = orig_mid.distance(midpoint_of(cs, ce))
          if dist < best_dist
            best_dist = dist
            best = edge
          end
        end

        return nil if best.nil? || best_dist > tolerance_in
        edge_spec(best, entity.transformation)
      end

      def self.midpoint_of(a, b)
        Geom::Point3d.new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0, (a.z + b.z) / 2.0)
      end

      # Snapshot edge geometry + BOTH adjacent faces' inward in-plane perpendiculars.
      # Positions and vectors projected through `xform` so the spec lives in the
      # target's PARENT frame (where the cutter will be created).
      #
      # Raises -32602 if the edge has fewer than 2 adjacent faces (boundary edges
      # of an open shape — chamfer/fillet undefined there).
      def self.edge_spec(edge, xform)
        faces = edge.faces.first(2)
        if faces.length < 2
          raise Core::StructuredError.new(-32602,
            "edge ##{edge.entityID} has #{faces.length} adjacent face(s); " \
            "chamfer/fillet requires a closed dihedral (2 faces)")
        end

        edge_pt  = edge.start.position
        edge_end = edge.end.position
        edge_dir = edge_end - edge_pt
        edge_dir.length = 1.0

        perp1 = in_face_perp_inward(faces[0], edge_pt, edge_dir)
        perp2 = in_face_perp_inward(faces[1], edge_pt, edge_dir)

        # Project everything through xform. For a Transformation, applying it
        # to a Point3d translates+rotates; applying to a Vector3d only rotates
        # (no translation), which is what we want for direction vectors.
        {
          start_pos: xform * edge_pt,
          end_pos:   xform * edge_end,
          perp1:     xform * perp1,
          perp2:     xform * perp2
        }
      end

      def self.reconstruct_edge(entities, spec)
        entities.add_line(cutter_path_start(spec), cutter_path_end(spec))
      end

      # SketchUp's Group#subtract returns an empty result group when operands
      # share coplanar faces. With profile=triangle whose vertices coincide
      # with the target's edge corner, the swept cutter prism shares THREE
      # face planes with the target cube:
      #   - the two side faces (in the perp1-face and perp2-face planes)
      #   - both end caps (in the target's faces perpendicular to the edge)
      # Subtract collapses these coincident faces and returns an empty group
      # ("Difference" with bbox 0–0; observed live in v0.0.1 smoke_check).
      #
      # Offset both endpoints of the cutter path:
      #   - along the edge direction by CUTTER_OFFSET (end caps poke past
      #     the target's faces — no end-cap coplanarity)
      #   - laterally by -(perp1+perp2)/2 * CUTTER_OFFSET (sides shift slightly
      #     out of the perp1/perp2 face planes — no side coplanarity)
      # The cutter is now a prism that pokes out of the target on all sides;
      # subtract cleanly removes the inner overlap (the chamfer wedge) plus
      # a CUTTER_OFFSET-thick smear that's invisible at any sane chamfer size.
      CUTTER_OFFSET = 0.005  # inches ≈ 0.127 mm; above SketchUp's 0.001-in tolerance

      def self.cutter_path_start(spec)
        edge_dir = (spec[:end_pos] - spec[:start_pos])
        edge_dir.length = 1.0
        spec[:start_pos]
          .offset(edge_dir.reverse, CUTTER_OFFSET)
          .offset(perp_avg(spec).reverse, CUTTER_OFFSET / 2.0)
      end

      def self.cutter_path_end(spec)
        edge_dir = (spec[:end_pos] - spec[:start_pos])
        edge_dir.length = 1.0
        spec[:end_pos]
          .offset(edge_dir, CUTTER_OFFSET)
          .offset(perp_avg(spec).reverse, CUTTER_OFFSET / 2.0)
      end

      # Mean of perp1 and perp2 (normalized) — points into the wedge interior.
      # Used to laterally shift the cutter so its side faces don't overlay the
      # target's adjacent face planes.
      def self.perp_avg(spec)
        v = Geom::Vector3d.new(
          spec[:perp1].x + spec[:perp2].x,
          spec[:perp1].y + spec[:perp2].y,
          spec[:perp1].z + spec[:perp2].z
        )
        v.length = 1.0 if v.length > 1e-10
        v
      end

      # Unit vector lying in `face`'s plane, perpendicular to `edge_dir`,
      # pointing from `edge_pt` toward the face interior. Use face.bounds.center
      # as the "interior reference" — the candidate perp whose dot product with
      # (face_center - edge_pt) is positive points inward.
      def self.in_face_perp_inward(face, edge_pt, edge_dir)
        n = face.normal
        # In-face perpendicular to edge: cross edge_dir with face normal.
        # By construction this lies in face plane and is ⊥ edge_dir.
        perp = edge_dir.cross(n)
        # Degenerate: edge_dir ∥ n (edge not in face plane — shouldn't happen
        # for a real edge of a face). Fall back to a hardcoded perpendicular.
        if perp.length < 1e-10
          perp = edge_dir.parallel?(Geom::Vector3d.new(0, 0, 1)) \
            ? Geom::Vector3d.new(1, 0, 0)
            : Geom::Vector3d.new(0, 0, 1)
        end
        perp.length = 1.0

        # Sign: pick direction toward face interior (face.bounds.center).
        to_interior = face.bounds.center - edge_pt
        perp = perp.reverse if perp.dot(to_interior) < 0
        perp
      end

      # Chamfer profile = right triangle in plane perpendicular to edge:
      #   a = cutter origin, b = a + perp1*d, c = a + perp2*d
      # Sweeping along the edge produces a triangular prism — exactly the
      # wedge of material to remove from the dihedral corner.
      # Origin is the offset cutter_path_start (NOT spec[:start_pos]); the
      # profile face must touch the path at its first endpoint, and the offset
      # avoids coplanar-face issues with subtract (see CUTTER_OFFSET above).
      def self.build_chamfer_profile(entities, spec, distance)
        origin = cutter_path_start(spec)
        a = origin
        b = origin.offset(spec[:perp1], distance)
        c = origin.offset(spec[:perp2], distance)
        entities.add_face(a, b, c)
      end

      # Fillet profile = closed face: quarter-arc (perp1·r → perp2·r around
      # arc_center) plus the corner vertex `origin` to close the loop. Sweeping
      # along the edge produces a quarter-cylinder volume (the wedge to remove).
      #   arc_center = origin + perp1·r + perp2·r
      #   P(θ) = arc_center − r·cos(θ)·perp2 − r·sin(θ)·perp1   (θ ∈ [0, π/2])
      #     θ=0     → arc_center − r·perp2 = origin + perp1·r
      #     θ=π/2   → arc_center − r·perp1 = origin + perp2·r
      # Origin is cutter_path_start for the same reasons as build_chamfer_profile.
      def self.build_fillet_profile(entities, spec, radius, segments)
        origin = cutter_path_start(spec)
        perp1  = spec[:perp1]
        perp2  = spec[:perp2]
        arc_center = origin.offset(perp1, radius).offset(perp2, radius)

        arc = (0..segments).map do |i|
          theta = Math::PI / 2 * i.to_f / segments
          arc_center
            .offset(perp2.reverse, radius * Math.cos(theta))
            .offset(perp1.reverse, radius * Math.sin(theta))
        end
        entities.add_face(arc + [origin])
      end

      # ===== shared helpers ==================================================

      def self.filter_edges(edges, indices)
        edges.select.with_index { |_, i| indices.include?(i) }
      end
    end
  end
end

# mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb
module MCPforSketchUp
  module Handlers
    module Joints
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units

      TOUCH_TOL   = 0.001 # SketchUp's tolerance, inches
      VOLUME_RTOL = 1e-4

      # ===== Mortise & Tenon =================================================
      #
      # All dimension params (width/height/depth/offset_*) accepted in **mm**
      # and converted to inches before SketchUp API. Defaults sized for
      # visibility on a 100mm cube — old monolith default of 1.0 inch becomes
      # invisibly small (1mm) under mm-conversion.

      def self.create_mortise_tenon(params)
        mortise_id = V.require_id(params, "mortise_id")
        tenon_id   = V.require_id(params, "tenon_id")
        width      = U.mm_to_inch(V.optional_positive(params, "width",  50.0))
        height     = U.mm_to_inch(V.optional_positive(params, "height", 25.0))
        depth      = U.mm_to_inch(V.optional_positive(params, "depth",  10.0))
        ox = U.mm_to_inch(V.optional_number(params, "offset_x"))
        oy = U.mm_to_inch(V.optional_number(params, "offset_y"))
        oz = U.mm_to_inch(V.optional_number(params, "offset_z"))

        model = E.active_model!
        model.start_operation("Mortise and Tenon", true)
        begin
          reset_joint_stats!
          mortise_board = E.find!(mortise_id)
          tenon_board   = E.find!(tenon_id)
          E.require_group_or_component!(mortise_board, "mortise board")
          E.require_group_or_component!(tenon_board,   "tenon board")

          direction = (tenon_board.bounds.center - mortise_board.bounds.center)
          mortise_face = closest_face(direction)
          tenon_face   = closest_face(direction.reverse)

          mortise_board = place_mortise(mortise_board, width, height, depth, mortise_face, ox, oy, oz)
          place_tenon(tenon_board,    width, height, depth, tenon_face,   ox, oy, oz)

          assert_some_cut!("Mortise and Tenon")
          model.commit_operation
          {
            "mortise" => MCPforSketchUp::Handlers::Geometry.describe_entity(mortise_board),
            "tenon"   => MCPforSketchUp::Handlers::Geometry.describe_entity(tenon_board),
            "boolean_cuts" => joint_cut_stats
          }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # ===== Pure joint geometry (no SketchUp) ===============================
      #
      # A box is [[min_x, min_y, min_z], [max_x, max_y, max_z]] in the boards'
      # common parent frame. The functions are unit-agnostic; their messages
      # treat the numbers as inches and print mm (lengths) / mm³ (volumes).

      # The face the tenon board touches the mortise board with: exactly one
      # axis touching (gap within tol of 0), the other two overlapping.
      def self.contact_area(mortise_box, tenon_box, tol = TOUCH_TOL)
        gaps = (0..2).map do |a|
          [mortise_box[0][a], tenon_box[0][a]].max - [mortise_box[1][a], tenon_box[1][a]].min
        end
        if gaps.any? { |g| g > tol }
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the mortise and tenon boards do not touch (gap #{format_mm(gaps.max)} mm); " \
            "move them so that one face of each lies against the other")
        end
        touching = (0..2).select { |a| gaps[a] >= -tol }
        if touching.empty?
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the mortise and tenon boards overlap; move them apart until " \
            "exactly one face of each lies against the other")
        end
        if touching.size > 1
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the mortise and tenon boards meet at an edge or a corner, not a face; " \
            "the joint needs a face-to-face contact")
        end
        axis  = touching[0]
        cross = (0..2).reject { |a| a == axis }
        # the tenon board is on the + side when its min face lies on the
        # mortise board's max face, otherwise its max face lies on the min face
        plus  = (tenon_box[0][axis] - mortise_box[1][axis]).abs <= (tenon_box[1][axis] - mortise_box[0][axis]).abs
        {
          axis:  axis,
          side:  plus ? 1 : -1,
          plane: plus ? mortise_box[1][axis] : mortise_box[0][axis],
          cross: cross,
          lo:    cross.map { |a| [mortise_box[0][a], tenon_box[0][a]].max },
          hi:    cross.map { |a| [mortise_box[1][a], tenon_box[1][a]].min }
        }
      end

      # The box of the joint: width x height centred on the contact area
      # (plus offsets), running depth into the mortise board along the axis.
      def self.joint_box(contact, width, height, depth, offsets, tol = TOUCH_TOL)
        axis = contact[:axis]
        u, v = contact[:cross]
        lo   = contact[:lo]
        hi   = contact[:hi]
        cu = (lo[0] + hi[0]) / 2.0 + offsets[u]
        cv = (lo[1] + hi[1]) / 2.0 + offsets[v]
        u0, u1 = cu - width / 2.0,  cu + width / 2.0
        v0, v1 = cv - height / 2.0, cv + height / 2.0
        if u0 < lo[0] - tol || u1 > hi[0] + tol || v0 < lo[1] - tol || v1 > hi[1] + tol
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the joint does not fit the contact area: #{format_mm(width)} x #{format_mm(height)} mm " \
            "at the requested offset, contact area is #{format_mm(hi[0] - lo[0])} x #{format_mm(hi[1] - lo[1])} mm; " \
            "reduce width/height or the offsets")
        end
        a0, a1 = contact[:side] > 0 ? [contact[:plane] - depth, contact[:plane]] : [contact[:plane], contact[:plane] + depth]
        min = [0, 0, 0]
        max = [0, 0, 0]
        min[axis], max[axis] = a0, a1
        min[u], max[u] = u0, u1
        min[v], max[v] = v0, v1
        [min, max]
      end

      # True when every transformation axis (x, y, z; any length) points along
      # one of the world axes.
      def self.axis_aligned?(axes, tol = 1e-9)
        axes.all? do |vec|
          len = Math.sqrt(vec.sum { |c| c * c })
          next false if len.zero?
          vec.any? { |c| (c.abs / len - 1.0).abs <= tol }
        end
      end

      # Post-check of the boolean result: nil when both boards changed by the
      # expected volume, otherwise a sentence naming the board that is off.
      # The mortise board may lose less than expected (a through mortise) but
      # not more.
      def self.joint_volume_problem(expected, mortise_before, mortise_after, tenon_before, tenon_after, rtol = VOLUME_RTOL)
        tol    = expected * rtol
        lost   = mortise_before - mortise_after
        gained = tenon_after - tenon_before
        if lost <= tol || lost > expected + tol
          return "mortise board volume changed by #{format_mm3(-lost)} mm³ " \
                 "(expected a loss of up to #{format_mm3(expected)} mm³)"
        end
        if (gained - expected).abs > tol
          return "tenon board volume changed by #{format_mm3(gained)} mm³ " \
                 "(expected a gain of #{format_mm3(expected)} mm³)"
        end
        nil
      end

      def self.format_mm(inches)
        format("%.2f", inches * U::MM)
      end

      def self.format_mm3(cubic_inches)
        format("%.1f", cubic_inches * U::MM**3)
      end

      # ===== Internal geometry helpers (carved from monolith) ================

      # --- Boolean-cut failure tracking (codex review) -----------------------
      # Group#subtract returns nil when a boolean cut fails — routine on
      # non-manifold geometry (see CLAUDE.md). The joint builders used to
      # swallow that nil and fall back to the UNCUT board, so the handler
      # reported success for a joint that produced no geometry. These helpers
      # count attempts + failures (single-threaded UI model ⇒ module ivars are
      # safe, same pattern as operations.rb @_last_stats) so the public handlers
      # can (a) raise on a COMPLETE no-op instead of faking success and
      # (b) surface partial failures via "boolean_cuts" in the response.
      def self.reset_joint_stats!
        @_joint_cuts_attempted = 0
        @_joint_cuts_failed    = 0
      end

      def self.subtract_tracked(cutter, target)
        result = cutter.subtract(target)
        @_joint_cuts_attempted += 1
        @_joint_cuts_failed    += 1 if result.nil?
        result
      end

      def self.assert_some_cut!(op_name)
        return unless @_joint_cuts_attempted.positive?
        return unless @_joint_cuts_failed == @_joint_cuts_attempted
        raise Core::StructuredError.new(-32603,
          "#{op_name} produced no geometry: all #{@_joint_cuts_attempted} boolean " \
          "cut(s) failed (likely non-manifold input geometry)")
      end

      def self.joint_cut_stats
        { "attempted" => @_joint_cuts_attempted, "failed" => @_joint_cuts_failed }
      end

      def self.closest_face(vector)
        # Совпавшие центры досок дают нулевой вектор: normalize! на нём либо
        # кидает, либо молча оставляет мусор, и «ближайшая грань» выбирается
        # произвольно. Отклоняем до нормализации.
        if vector.length < 1e-9
          raise Core::StructuredError.new(-32602,
            "cannot infer joint direction: board centers coincide — " \
            "separate the boards or reposition them")
        end
        v = vector.clone
        v.normalize!
        ax, ay, az = v.x.abs, v.y.abs, v.z.abs
        if ax >= ay && ax >= az then v.x > 0 ? :east  : :west
        elsif ay >= az          then v.y > 0 ? :north : :south
        else                          v.z > 0 ? :top   : :bottom
        end
      end

      def self.face_origin(face_dir, bounds, w, h, ox, oy, oz)
        case face_dir
        when :east   then [bounds.max.x,                bounds.center.y - w/2 + oy, bounds.center.z - h/2 + oz]
        when :west   then [bounds.min.x,                bounds.center.y - w/2 + oy, bounds.center.z - h/2 + oz]
        when :north  then [bounds.center.x - w/2 + ox,  bounds.max.y,                bounds.center.z - h/2 + oz]
        when :south  then [bounds.center.x - w/2 + ox,  bounds.min.y,                bounds.center.z - h/2 + oz]
        when :top    then [bounds.center.x - w/2 + ox,  bounds.center.y - h/2 + oy,  bounds.max.z]
        when :bottom then [bounds.center.x - w/2 + ox,  bounds.center.y - h/2 + oy,  bounds.min.z]
        end
      end

      def self.place_mortise(board, w, h, d, face_dir, ox, oy, oz)
        origin = face_origin(face_dir, board.bounds, w, h, ox, oy, oz)
        # Cutter must be a SIBLING of board (in board.parent.entities) for
        # Group#subtract to work. board.bounds returns coords in the parent
        # frame, so the cutter built from `origin` lands in the same frame.
        # For nested boards parent != model.active_entities, so we must NOT
        # use active_entities here.
        cutter = board.parent.entities.add_group
        push_cutter_face(cutter.entities, origin, w, h, d, face_dir)
        # Group#subtract: A.subtract(B) returns "B - A" (verified empirically).
        # To cut a mortise out of board, we call cutter.subtract(board), which
        # returns board - cutter (board with mortise hole). Both groups erased;
        # new group returned.
        result = subtract_tracked(cutter, board)
        result || board                    # if subtract returned nil, fall back to original (still valid)
      end

      def self.place_tenon(board, w, h, d, face_dir, ox, oy, oz)
        # NB: same origin construction as mortise but extrudes outward instead
        # of cutting inward. Implementation detail kept compatible with monolith.
        #
        # Frames in play:
        #   - origin:                board.parent frame (because board.bounds
        #                            is parent-frame for Group/ComponentInstance)
        #   - prot.definition.entities: parent frame (we build the face there)
        #   - target collection:     board.entities (board's LOCAL frame)
        #
        # We need the new instance to land at `origin` in board.parent's frame,
        # NOT origin in board's local frame. World position of an instance
        # added to board.entities is parent_t * T_board * T_inst * geom; with
        # T_inst = T_board.inverse the T_board's cancel and we get
        # parent_t * geom — correctly placing geometry at parent-frame origin
        # for both top-level boards (T_board=identity, T_inst=identity) and
        # nested/transformed boards.
        #
        # `prot.transform!` accumulates T_inv into prot.transformation but does
        # NOT rewrite the geometry inside prot.definition. So we read back
        # prot.transformation (= T_inv) and pass it to add_instance.
        entities = E.mutable_entity_collection(board)
        origin   = face_origin(face_dir, board.bounds, w, h, ox, oy, oz)
        prot     = MCPforSketchUp::Helpers::Entities.active_model!.active_entities.add_group
        begin
          push_cutter_face(prot.entities, origin, w, h, d, face_dir, outward: true)
          prot.transform!(board.transformation.inverse)
          # Sketchup::Group#definition is documented public API — no respond_to? guard.
          entities.add_instance(prot.definition, prot.transformation) if prot.valid?
        ensure
          # Always erase prot, even if any step raised — otherwise we leak an
          # orphan group into active_entities.
          prot.erase! if prot && prot.valid?
        end
      end

      def self.push_cutter_face(entities, o, w, h, d, face_dir, outward: false)
        # `outward` controls which side of the face is extruded:
        #   - mortise (cut inward):  outward=false → push into the board (negative)
        #   - tenon (extrude outward): outward=true → push out of the board (positive)
        # face_dir gives the axis sign convention; outward flips it.
        case face_dir
        when :east, :west
          face = entities.add_face(
            [o[0], o[1],     o[2]],
            [o[0], o[1]+w,   o[2]],
            [o[0], o[1]+w,   o[2]+h],
            [o[0], o[1],     o[2]+h])
          face.pushpull((face_dir == :east ? -d : d) * (outward ? -1 : 1))
        when :north, :south
          face = entities.add_face(
            [o[0],   o[1], o[2]],
            [o[0]+w, o[1], o[2]],
            [o[0]+w, o[1], o[2]+h],
            [o[0],   o[1], o[2]+h])
          face.pushpull((face_dir == :north ? -d : d) * (outward ? -1 : 1))
        when :top, :bottom
          face = entities.add_face(
            [o[0],   o[1],   o[2]],
            [o[0]+w, o[1],   o[2]],
            [o[0]+w, o[1]+h, o[2]],
            [o[0],   o[1]+h, o[2]])
          face.pushpull((face_dir == :top ? -d : d) * (outward ? -1 : 1))
        end
      end
    end
  end
end

# su_mcp/su_mcp/handlers/joints.rb
module MCPforSketchUp
  module Handlers
    module Joints
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units

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
        ox = U.mm_to_inch((params["offset_x"] || 0.0).to_f)
        oy = U.mm_to_inch((params["offset_y"] || 0.0).to_f)
        oz = U.mm_to_inch((params["offset_z"] || 0.0).to_f)

        model = E.active_model!
        model.start_operation("Mortise and Tenon", true)
        begin
          mortise_board = E.find!(mortise_id)
          tenon_board   = E.find!(tenon_id)
          E.require_group_or_component!(mortise_board, "mortise board")
          E.require_group_or_component!(tenon_board,   "tenon board")

          direction = (tenon_board.bounds.center - mortise_board.bounds.center)
          mortise_face = closest_face(direction)
          tenon_face   = closest_face(direction.reverse)

          mortise_board = place_mortise(mortise_board, width, height, depth, mortise_face, ox, oy, oz)
          place_tenon(tenon_board,    width, height, depth, tenon_face,   ox, oy, oz)

          model.commit_operation
          {
            "mortise" => MCPforSketchUp::Handlers::Geometry.describe_entity(mortise_board),
            "tenon"   => MCPforSketchUp::Handlers::Geometry.describe_entity(tenon_board)
          }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # ===== Dovetail ========================================================

      def self.create_dovetail(params)
        tail_id  = V.require_id(params, "tail_id")
        pin_id   = V.require_id(params, "pin_id")
        width    = U.mm_to_inch(V.optional_positive(params, "width",  50.0))
        height   = U.mm_to_inch(V.optional_positive(params, "height", 50.0))
        depth    = U.mm_to_inch(V.optional_positive(params, "depth",  15.0))
        angle    = V.optional_positive(params, "angle", 15.0)  # degrees, не конвертим
        num_tails = V.optional_int_positive(params, "num_tails", 3)
        ox = U.mm_to_inch((params["offset_x"] || 0.0).to_f)
        oy = U.mm_to_inch((params["offset_y"] || 0.0).to_f)
        oz = U.mm_to_inch((params["offset_z"] || 0.0).to_f)

        model = E.active_model!
        model.start_operation("Dovetail Joint", true)
        begin
          tail = E.find!(tail_id)
          pin  = E.find!(pin_id)
          E.require_group_or_component!(tail, "tail board")
          E.require_group_or_component!(pin,  "pin board")

          carve_tails(tail, width, height, depth, angle, num_tails, ox, oy, oz)
          carve_pins(pin,   width, height, depth, angle, num_tails, ox, oy, oz)

          model.commit_operation
          {
            "tail" => MCPforSketchUp::Handlers::Geometry.describe_entity(tail),
            "pin"  => MCPforSketchUp::Handlers::Geometry.describe_entity(pin)
          }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # ===== Finger joint ====================================================

      def self.create_finger_joint(params)
        b1_id  = V.require_id(params, "board1_id")
        b2_id  = V.require_id(params, "board2_id")
        width  = U.mm_to_inch(V.optional_positive(params, "width",  50.0))
        height = U.mm_to_inch(V.optional_positive(params, "height", 25.0))
        depth  = U.mm_to_inch(V.optional_positive(params, "depth",  10.0))
        num_fingers = V.optional_int_positive(params, "num_fingers", 5)
        ox = U.mm_to_inch((params["offset_x"] || 0.0).to_f)
        oy = U.mm_to_inch((params["offset_y"] || 0.0).to_f)
        oz = U.mm_to_inch((params["offset_z"] || 0.0).to_f)

        model = E.active_model!
        model.start_operation("Finger Joint", true)
        begin
          b1 = E.find!(b1_id)
          b2 = E.find!(b2_id)
          E.require_group_or_component!(b1, "board1")
          E.require_group_or_component!(b2, "board2")

          carve_board1_fingers(b1, width, height, depth, num_fingers, ox, oy, oz)
          b2 = carve_board2_slots(b2, width, height, depth, num_fingers, ox, oy, oz)

          model.commit_operation
          {
            "board1" => MCPforSketchUp::Handlers::Geometry.describe_entity(b1),
            "board2" => MCPforSketchUp::Handlers::Geometry.describe_entity(b2)
          }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # ===== Internal geometry helpers (carved from monolith) ================

      def self.closest_face(vector)
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
        result = cutter.subtract(board)
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
        entities = E.entity_collection(board)
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

      def self.carve_tails(board, width, height, depth, angle_deg, num_tails, ox, oy, oz)
        entities = E.entity_collection(board)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        tail_w = width / (2 * num_tails - 1)
        angle  = angle_deg * Math::PI / 180.0
        bottom_w = tail_w + 2 * depth * Math.tan(angle)

        group = entities.add_group
        num_tails.times do |i|
          tx = cx - width/2 + tail_w * 2 * i
          face = group.entities.add_face(
            [tx - tail_w/2,    cy - height/2, cz],
            [tx + tail_w/2,    cy - height/2, cz],
            [tx + bottom_w/2,  cy - height/2, cz - depth],
            [tx - bottom_w/2,  cy - height/2, cz - depth])
          face.pushpull(height)
        end
      end

      def self.carve_pins(board, width, height, depth, angle_deg, num_tails, ox, oy, oz)
        entities = E.entity_collection(board)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        tail_w = width / (2 * num_tails - 1)
        angle  = angle_deg * Math::PI / 180.0
        bottom_w = tail_w + 2 * depth * Math.tan(angle)

        pin_group = entities.add_group
        face = pin_group.entities.add_face(
          [cx - width/2, cy - height/2, cz],
          [cx + width/2, cy - height/2, cz],
          [cx + width/2, cy + height/2, cz],
          [cx - width/2, cy + height/2, cz])
        face.pushpull(depth)

        num_tails.times do |i|
          break unless pin_group.valid?  # if a previous subtract returned nil, stop
          tx = cx - width/2 + tail_w * 2 * i
          cutter = entities.add_group
          cf = cutter.entities.add_face(
            [tx - tail_w/2,    cy - height/2, cz],
            [tx + tail_w/2,    cy - height/2, cz],
            [tx + bottom_w/2,  cy - height/2, cz - depth],
            [tx - bottom_w/2,  cy - height/2, cz - depth])
          cf.pushpull(height)
          # Group#subtract reversed semantics: cutter.subtract(pin_group) returns
          # pin_group - cutter (= pin with tail slot carved). Both groups erased.
          new_pin = cutter.subtract(pin_group)
          pin_group = new_pin if new_pin
        end
      end

      def self.carve_board1_fingers(board, width, height, depth, num_fingers, ox, oy, oz)
        entities = E.entity_collection(board)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        # Use float division — Integer / Integer would truncate at 0 for small inputs
        finger_w = width / num_fingers.to_f

        group = entities.add_group
        face = group.entities.add_face(
          [cx - width/2, cy - height/2, cz],
          [cx + width/2, cy - height/2, cz],
          [cx + width/2, cy + height/2, cz],
          [cx - width/2, cy + height/2, cz])
        # Extrude FIRST: face reference would be invalidated by subsequent
        # Group#subtract operations below, so push before the loop runs.
        face.pushpull(depth)
        (num_fingers / 2).times do |i|
          break unless group.valid?
          tx = cx - width/2 + finger_w * (2 * i + 1)
          cutter = entities.add_group
          cf = cutter.entities.add_face(
            [tx - finger_w/2, cy - height/2, cz],
            [tx + finger_w/2, cy - height/2, cz],
            [tx + finger_w/2, cy + height/2, cz],
            [tx - finger_w/2, cy + height/2, cz])
          cf.pushpull(depth)
          # cutter.subtract(group) returns group - cutter (board1 with finger slot).
          new_group = cutter.subtract(group)
          group = new_group if new_group
        end
      end

      def self.carve_board2_slots(board, width, height, depth, num_fingers, ox, oy, oz)
        c = board.bounds.center
        cx, cy, cz = c.x + ox, c.y + oy, c.z + oz
        # Use float division — Integer / Integer would truncate at 0 for small inputs
        finger_w = width / num_fingers.to_f

        cuts = num_fingers / 2 + num_fingers % 2
        current = board
        cuts.times do |i|
          break unless current.valid?
          tx = cx - width/2 + finger_w * 2 * i
          # Cutter must be SIBLING of `current` for Group#subtract (parent.entities,
          # NOT active_entities — handles nested boards correctly).
          cutter = current.parent.entities.add_group
          cf = cutter.entities.add_face(
            [tx - finger_w/2, cy - height/2, cz],
            [tx + finger_w/2, cy - height/2, cz],
            [tx + finger_w/2, cy + height/2, cz],
            [tx - finger_w/2, cy + height/2, cz])
          cf.pushpull(depth)
          # cutter.subtract(current) returns current - cutter (board2 with slot).
          new_board = cutter.subtract(current)
          current = new_board if new_board
        end
        current  # return final board reference
      end
    end
  end
end

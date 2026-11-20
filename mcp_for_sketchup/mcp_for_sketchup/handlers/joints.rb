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
      #
      # The boards touch face to face in one parent, and the joint is centred
      # on their contact area (contact_area, joint_box). One operation cuts
      # the mortise and joins the tenon, and commits only when verify_joint!
      # accepts both results; anything else rolls back, so no half-built
      # joint reaches the model.

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
          mortise_board = E.find!(mortise_id)
          tenon_board   = E.find!(tenon_id)
          E.require_group_or_component!(mortise_board, "mortise board")
          E.require_group_or_component!(tenon_board,   "tenon board")
          require_joinable!(model, mortise_board, tenon_board)

          contact = contact_area(board_box(mortise_board), board_box(tenon_board))
          box     = joint_box(contact, width, height, depth, [ox, oy, oz])

          mortise_before   = mortise_board.volume
          tenon_before     = tenon_board.volume
          mortise_identity = E.identity_of(mortise_board)
          tenon_identity   = E.identity_of(tenon_board)

          mortise = cut_mortise(mortise_board, box)
          tenon   = attach_tenon(tenon_board, box)
          verify_joint!(mortise, tenon, width * height * depth, mortise_before, tenon_before)
          E.restore_identity!(mortise, mortise_identity)
          E.restore_identity!(tenon,   tenon_identity)

          # The response is built before commit_operation: commit has been
          # seen to invalidate the proxies of solid-operation results
          # (operations.rb, run_edge_op).
          response = {
            "mortise" => MCPforSketchUp::Handlers::Geometry.describe_entity(mortise),
            "tenon"   => MCPforSketchUp::Handlers::Geometry.describe_entity(tenon)
          }
          model.commit_operation
          response
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

      # ===== Building and checking the joint (SketchUp) ======================

      # What to try when SketchUp's solid tools fail on a joint or give a
      # result the post-check refuses.
      SOLID_TOOLS_ADVICE =
        "A face of the joint that lies in a face of a board can defeat SketchUp's solid " \
        "tools: make the depth differ from the mortise board's thickness, keep the joint " \
        "off the edge of the contact area, or build this joint with eval_ruby"

      # The board's bounding box in its parent's frame, as plain Floats: a
      # SketchUp Length compares within SketchUp's tolerance, and the pure
      # functions above apply their own.
      def self.board_box(board)
        b = board.bounds
        [[b.min.x.to_f, b.min.y.to_f, b.min.z.to_f], [b.max.x.to_f, b.max.y.to_f, b.max.z.to_f]]
      end

      # What lets the bounding boxes stand for the boards: one parent (the
      # boxes share its frame), axes parallel to the parent's (only then does
      # a box fit its board) and closed solids (the solid operations and the
      # volume check need them).
      #
      # An open group comes first. While a group is open, SketchUp reports
      # the transformations and bounds of its entities in world coordinates
      # (model.edit_transform holds the group's own), so in a rotated open
      # group the boards look rotated, and the board check would tell the
      # user to rotate boards that are placed correctly: that case is refused
      # with the advice to close the group. An open group that is only moved
      # keeps working. A board that is itself open reports an identity
      # transformation, and the solid operations would erase the group the
      # user is working in.
      def self.require_joinable!(model, mortise, tenon)
        boards = { "mortise board" => mortise, "tenon board" => tenon }
        open_path = model.active_path || []
        boards.each do |label, board|
          next unless open_path.include?(board)
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the #{label} is open for editing; close it and try again")
        end
        unless mortise.parent == tenon.parent
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the mortise and tenon boards are not in the same group; move them into one " \
            "group or component, or both to the top level of the model")
        end
        if !open_path.empty? && mortise.parent == model.active_entities.parent &&
           !aligned_transformation?(model.edit_transform)
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the group or component that holds the boards is open for editing and rotated " \
            "by an angle that is not a multiple of 90°; close it and try again")
        end
        boards.each do |label, board|
          next if aligned_transformation?(board.transformation)
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the #{label} is rotated by an angle that is not a multiple of 90°, and the joint " \
            "is placed from bounding boxes; rotate the board to a multiple of 90° or build " \
            "this joint with eval_ruby")
        end
        boards.each do |label, board|
          next if board.manifold?
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the #{label} is not a solid, and the joint is built with SketchUp's solid tools; " \
            "close its holes and remove stray faces and edges until Entity Info calls it a " \
            "solid, then try again")
        end
      end

      # True when the transformation keeps its axes parallel to its parent's.
      def self.aligned_transformation?(t)
        axis_aligned?([t.xaxis.to_a, t.yaxis.to_a, t.zaxis.to_a])
      end

      # make_box's x, y, z, w, d, h for the box [[min], [max]].
      def self.make_box_args(box)
        min, max = box
        min + (0..2).map { |a| max[a] - min[a] }
      end

      # The mortise: a cutter of the joint's box, cut out of the board with
      # the reversed Group#subtract — cutter.subtract(board) returns
      # board − cutter and erases both. The cutter is the board's sibling
      # (board.parent.entities, not active_entities): Group#subtract needs
      # siblings, and the box is in the parent's frame. Returns the new
      # mortise board.
      def self.cut_mortise(board, box)
        cutter = MCPforSketchUp::Helpers::Geometry.make_box(board.parent.entities, *make_box_args(box))
        result = cutter.subtract(board)
        solid_result!(result, "cut the mortise into the mortise board")
      end

      # The tenon: a piece of the joint's box, the board's sibling like the
      # cutter, joined to it with union so the board stays one solid (a
      # nested group would not be part of its body). Returns the new tenon
      # board.
      def self.attach_tenon(board, box)
        piece = MCPforSketchUp::Helpers::Geometry.make_box(board.parent.entities, *make_box_args(box))
        result = piece.union(board)
        solid_result!(result, "join the tenon to the tenon board")
      end

      # A solid operation's result, or -32603 when it returned nil or a group
      # that is already gone.
      def self.solid_result!(result, what)
        return result if result && result.valid?
        raise MCPforSketchUp::Core::StructuredError.new(-32603,
          "SketchUp could not #{what}; the operation was rolled back and the model is " \
          "unchanged. #{SOLID_TOOLS_ADVICE}")
      end

      # True when the group's faces make one connected shell: every face is
      # among the first face's all_connected. A tenon that misses the board's
      # real face comes out of the union as a second shell.
      def self.single_shell?(group)
        faces = E.entity_collection(group).grep(Sketchup::Face)
        return false if faces.empty?
        (faces - faces.first.all_connected).empty?
      end

      # The post-check, before anything is committed. The bounding boxes
      # cannot see a board that does not fill its box where the boards touch
      # (an L-shape, a notch, a taper), geometry rotated inside an unrotated
      # group, or the empty group subtract returns when the cutter shares face
      # planes with the board; the results show all of them. -32603 unless
      # both results are solids, their volumes changed as joint_volume_problem
      # expects and the tenon is one shell with its board.
      def self.verify_joint!(mortise, tenon, expected, mortise_before, tenon_before)
        problem =
          if !mortise.manifold?
            "the mortise board is no longer a solid"
          elsif !tenon.manifold?
            "the tenon board is no longer a solid"
          elsif (volume = joint_volume_problem(expected, mortise_before, mortise.volume, tenon_before, tenon.volume))
            volume
          elsif !single_shell?(tenon)
            "the tenon did not join the tenon board's body (it is a separate shell)"
          end
        return if problem.nil?

        raise MCPforSketchUp::Core::StructuredError.new(-32603,
          "the joint was not committed: #{problem}; the operation was rolled back and the " \
          "model is unchanged. Each board must fill its bounding box where the boards touch " \
          "(no notch, taper or L-shape). #{SOLID_TOOLS_ADVICE}")
      end
    end
  end
end

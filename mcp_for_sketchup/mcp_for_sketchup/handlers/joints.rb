# mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb
module MCPforSketchUp
  module Handlers
    module Joints
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities
      U = MCPforSketchUp::Helpers::Units
      O = MCPforSketchUp::Helpers::Operation
      F = MCPforSketchUp::Helpers::Frames

      TOUCH_TOL   = 0.001 # SketchUp's tolerance, inches
      VOLUME_RTOL = 1e-4
      AXIS_NAMES  = %w[X Y Z].freeze

      # ===== Mortise & Tenon =================================================
      #
      # All dimension params (width/height/depth/offset_*) accepted in **mm**
      # and converted to inches before SketchUp API. Defaults sized for
      # visibility on a 100mm cube — old monolith default of 1.0 inch becomes
      # invisibly small (1mm) under mm-conversion.
      #
      # The boards touch face to face in one parent, and the joint is centred
      # on their contact area (contact_area, joint_box). The boxes are WORLD
      # boxes (block A, §6.6a), so the joint follows the model's X, Y and Z
      # and comes out the same whether or not the boards' group is open for
      # editing, as every tool's bbox_mm does. One operation cuts the mortise
      # and joins the tenon, and commits only when verify_joint! accepts both
      # results; anything else rolls back, so no half-built joint reaches the
      # model.

      def self.create_mortise_tenon(params)
        mortise_id = V.require_id(params, "mortise_id")
        tenon_id   = V.require_id(params, "tenon_id")
        if mortise_id == tenon_id
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "mortise_id and tenon_id name the same board (entity #{mortise_id}); " \
            "a joint needs two different boards")
        end
        width_mm   = V.optional_positive(params, "width",  50.0)
        height_mm  = V.optional_positive(params, "height", 25.0)
        depth_mm   = V.optional_positive(params, "depth",  10.0)
        ox = U.mm_to_inch(V.optional_number(params, "offset_x"))
        oy = U.mm_to_inch(V.optional_number(params, "offset_y"))
        oz = U.mm_to_inch(V.optional_number(params, "offset_z"))
        require_box_dimensions!("width" => width_mm, "height" => height_mm, "depth" => depth_mm)
        width      = U.mm_to_inch(width_mm)
        height     = U.mm_to_inch(height_mm)
        depth      = U.mm_to_inch(depth_mm)

        model = E.active_model!
        O.run(model, "Mortise and Tenon") do
          mortise_board = E.find!(mortise_id)
          tenon_board   = E.find!(tenon_id)
          E.require_group_or_component!(mortise_board, "mortise board")
          E.require_group_or_component!(tenon_board,   "tenon board")
          parent = require_joinable!(model, mortise_board, tenon_board)

          mortise_box = board_box(mortise_board, parent)
          contact     = contact_area(mortise_box, board_box(tenon_board, parent))
          box         = joint_box(contact, width, height, depth, [ox, oy, oz])
          thickness   = mortise_box[1][contact[:axis]] - mortise_box[0][contact[:axis]]
          # The boxes are world; SketchUp reports the boards' volumes in their
          # parent's frame, which a scaled parent shrinks or grows by the
          # determinant of its matrix.
          scale       = F.determinant(parent).abs
          cut         = width * height * [depth, thickness].min / scale
          joint       = width * height * depth / scale

          mortise_before   = mortise_board.volume
          tenon_before     = tenon_board.volume
          mortise_identity = E.identity_of(mortise_board)
          tenon_identity   = E.identity_of(tenon_board)

          mortise = cut_mortise(mortise_board, box, parent)
          tenon   = attach_tenon(tenon_board, box, parent)
          verify_joint!(mortise, tenon, cut, joint, mortise_before, tenon_before)
          E.restore_identity!(mortise, mortise_identity)
          E.restore_identity!(tenon,   tenon_identity)

          # The response is the block's value, so it is built before
          # commit_operation: commit has been seen to invalidate the proxies
          # of solid-operation results (operations.rb, run_edge_op).
          {
            "mortise" => MCPforSketchUp::Handlers::Geometry.describe_entity(mortise),
            "tenon"   => MCPforSketchUp::Handlers::Geometry.describe_entity(tenon)
          }
        end
      end

      # make_box merges the corners of a box thinner than SketchUp's merge
      # tolerance (0.001", 0.0254 mm), so the joint refuses what
      # create_component refuses for a cube. dims_mm: { "width" => mm, ... }.
      def self.require_box_dimensions!(dims_mm)
        floor = MCPforSketchUp::Handlers::Geometry::MIN_DIMENSION_MM_BOX
        dims_mm.each do |key, mm|
          next if mm >= floor
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "#{key} must be >= #{floor} mm, got #{mm} — sub-millimeter geometry collapses " \
            "into SketchUp's merge tolerance")
        end
      end

      # ===== Pure joint geometry (no SketchUp) ===============================
      #
      # A box is [[min_x, min_y, min_z], [max_x, max_y, max_z]] in world
      # coordinates. The functions are unit-agnostic; their messages treat
      # the numbers as inches and print mm (lengths) / mm³ (volumes).

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
          # the axis of the smallest overlap: the shortest way apart
          axis = (0..2).max_by { |a| gaps[a] }
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the mortise and tenon boards overlap by #{format_mm(-gaps[axis])} mm along " \
            "#{AXIS_NAMES[axis]}; move them apart along #{AXIS_NAMES[axis]} until exactly " \
            "one face of each lies against the other")
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
      # expected volumes, otherwise [sentence, kind]. The sentence starts with
      # the board that is off ("mortise board …" / "tenon board …"). `cut` is
      # the volume the mortise board must lose, `joint` the volume the tenon
      # board must gain (the whole joint's box). The mortise board loses
      # exactly the part of the joint's box inside it — width × height ×
      # min(depth, its thickness along the joint axis), so a through mortise
      # is fine. The kind picks the advice:
      #   :shortfall  the mortise board lost something, but less than the
      #               pocket: the box met an earlier pocket, or a notch, gap
      #               or taper of the board, where the tenon would fill space
      #               the cut did not free;
      #   :cut        any other wrong loss: nothing removed, too much, a gain;
      #   :join       the tenon board is off.
      def self.joint_volume_problem(cut, joint, mortise_before, mortise_after, tenon_before, tenon_after, rtol = VOLUME_RTOL)
        lost   = mortise_before - mortise_after
        gained = tenon_after - tenon_before
        tol    = cut * rtol
        if (lost - cut).abs > tol
          kind = lost > tol && lost < cut - tol ? :shortfall : :cut
          return ["mortise board #{format_change(lost, 'lost', 'gained', tol)} mm³ " \
                  "(expected a loss of #{format_mm3(cut)} mm³)", kind]
        end
        if (gained - joint).abs > joint * rtol
          return ["tenon board #{format_change(gained, 'gained', 'lost', joint * rtol)} mm³ " \
                  "(expected a gain of #{format_mm3(joint)} mm³)", :join]
        end
        nil
      end

      # "<verb> X" for a volume change expected to go the way of `verb`, or
      # "<opposite> X" when it went the other way by more than tol. X (mm³)
      # is never negative, nor a negative zero.
      def self.format_change(amount, verb, opposite, tol)
        return "#{opposite} #{format_mm3(-amount)}" if amount < -tol
        "#{verb} #{format_mm3(amount.positive? ? amount : 0.0)}"
      end

      def self.format_mm(inches)
        format("%.2f", inches * U::MM)
      end

      def self.format_mm3(cubic_inches)
        format("%.1f", cubic_inches * U::MM**3)
      end

      # ===== Building and checking the joint (SketchUp) ======================

      # What to try when the subtract that cuts the mortise fails, or leaves a
      # mortise board the post-check refuses.
      CUT_ADVICE =
        "A face of the cutter that lies in a face of the mortise board can defeat SketchUp's " \
        "subtract: make the depth differ from the mortise board's thickness, keep the joint " \
        "off the edge of the contact area, or build this joint with eval_ruby"

      # The same for the union that joins the tenon to the tenon board.
      JOIN_ADVICE =
        "A side of the tenon that lies in a face of the tenon board can defeat SketchUp's " \
        "union: keep the joint off the edge of the contact area, or build this joint with " \
        "eval_ruby"

      # What to try when the mortise board lost less than the pocket's volume
      # (§6.6a): the general sentence already says that the pocket must not
      # meet an earlier one.
      SHORTFALL_ADVICE =
        "Make the joint shallower, or move it with the offsets, so that its pocket stays clear of the " \
        "earlier one"

      # A board whose rotation in the model, its own and that of the groups
      # holding it, is not a multiple of 90°; raised as "the <label> …".
      ROTATION_MESSAGE = "is rotated in the model by an angle that is not a multiple of 90°, and the joint " \
        "is placed along the model's axes from bounding boxes; rotate the board, or the group or component " \
        "that holds it, to a multiple of 90°, or build this joint with eval_ruby"

      # What to try when the cut leaves the mortise board in separate pieces.
      SPLIT_ADVICE =
        "A through mortise as wide as the mortise board splits it: make the joint narrower " \
        "than the mortise board or its depth less than the board's thickness, so that the " \
        "pocket does not cut the board in two"

      # The board's world box, as plain Floats (Frames.world_box): its
      # definition's bounds through the matrix of its parents and its own
      # transformation. The definition's bounds do not change when the
      # boards' group is opened for editing, and the matrix gives the same
      # world placement open or closed, so the box does not either. It fits
      # the board because the board is aligned with the world axes
      # (require_joinable!).
      def self.board_box(board, parent)
        F.world_box(board.definition.bounds, F.multiply(parent, F.matrix_of(board.transformation)))
      end

      # What lets the world boxes stand for the boards, in this order: no
      # board is open for editing (it reports an identity transformation,
      # and the solid operations would erase the group the user is working
      # in); one parent (the cutter and the tenon piece are built beside
      # the boards); neither board inside a shared definition (the joint
      # would appear in every copy); each board aligned with the world axes,
      # its own rotation and its groups' together (only then does a box fit
      # its board); closed solids (the solid operations and the volume check
      # need them). Returns the matrix of the boards' parents.
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
        parent = F.require_unshared!(mortise, "the mortise board").matrix
        F.require_unshared!(tenon, "the tenon board")
        boards.each do |label, board|
          next if world_aligned?(F.multiply(parent, F.matrix_of(board.transformation)))
          raise MCPforSketchUp::Core::StructuredError.new(-32602, "the #{label} #{ROTATION_MESSAGE}")
        end
        boards.each do |label, board|
          next if board.manifold?
          raise MCPforSketchUp::Core::StructuredError.new(-32602,
            "the #{label} is not a solid, and the joint is built with SketchUp's solid tools; " \
            "close its holes, remove stray faces and edges, and explode or move out any group " \
            "or component nested in it (an earlier version of this tool left its tenon nested " \
            "like that), until Entity Info calls it a solid, then try again")
        end
        parent
      end

      # True when the matrix keeps its axes along the world's (rotations by
      # multiples of 90°, any scale or mirror).
      def self.world_aligned?(m)
        axis_aligned?([m[0, 3], m[4, 3], m[8, 3]])
      end

      # make_box's x, y, z, w, d, h for the box [[min], [max]].
      def self.make_box_args(box)
        min, max = box
        min + (0..2).map { |a| max[a] - min[a] }
      end

      # The mortise: a cutter of the joint's box, cut out of the board with
      # the reversed Group#subtract — cutter.subtract(board) returns
      # board − cutter and erases both. The cutter is the board's sibling
      # (place_box): Group#subtract needs siblings. Returns the new mortise
      # board.
      def self.cut_mortise(board, box, parent)
        cutter = place_box(board, box, parent)
        result = cutter.subtract(board)
        solid_result!(result, "cut the mortise into the mortise board", CUT_ADVICE)
      end

      # The tenon: a piece of the joint's box, the board's sibling like the
      # cutter, joined to it with union so the board stays one solid (a
      # nested group would not be part of its body). Returns the new tenon
      # board.
      def self.attach_tenon(board, box, parent)
        piece = place_box(board, box, parent)
        result = piece.union(board)
        solid_result!(result, "join the tenon to the tenon board", JOIN_ADVICE)
      end

      # A group of the joint's box (world inches) in the board's parent
      # (board.parent.entities, not active_entities), taken from the world
      # into that parent's frame by the inverse of the parents' matrix. At
      # the top level, and in a group open for editing, the parents' matrix
      # is the identity and the box stays where make_box built it.
      def self.place_box(board, box, parent)
        piece = MCPforSketchUp::Helpers::Geometry.make_box(board.parent.entities, *make_box_args(box))
        piece.transform!(F.transformation(F.inverse(parent))) unless F.identity?(parent)
        piece
      end

      # A solid operation's result, or -32603 when it returned nil or a group
      # that is already gone; `advice` is what to try for that operation.
      def self.solid_result!(result, what, advice)
        return result if result && result.valid?
        raise MCPforSketchUp::Core::StructuredError.new(-32603,
          "SketchUp could not #{what}; the operation was rolled back and the model is " \
          "unchanged. #{advice}")
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
      # (an L-shape, a notch, a taper), a pocket that meets an earlier one,
      # geometry rotated inside an unrotated group, or the empty group
      # subtract returns when the cutter shares face planes with the board;
      # the results show all of them. -32603 unless both results are solids,
      # their volumes changed as joint_volume_problem expects, the mortise
      # board is still one piece (a through mortise as wide as the board cuts
      # it in two) and the tenon is one shell with its board. The advice
      # follows the board that is off: the cut made the mortise board, the
      # union the tenon board.
      def self.verify_joint!(mortise, tenon, cut, joint, mortise_before, tenon_before)
        problem, advice =
          if !mortise.manifold?
            ["the mortise board is no longer a solid", CUT_ADVICE]
          elsif !tenon.manifold?
            ["the tenon board is no longer a solid", JOIN_ADVICE]
          elsif (volume = joint_volume_problem(cut, joint, mortise_before, mortise.volume, tenon_before, tenon.volume))
            sentence, kind = volume
            [sentence, { shortfall: SHORTFALL_ADVICE, cut: CUT_ADVICE, join: JOIN_ADVICE }.fetch(kind)]
          elsif !single_shell?(mortise)
            ["the cut split the mortise board into separate pieces", SPLIT_ADVICE]
          elsif !single_shell?(tenon)
            ["the tenon did not join the tenon board's body (it is a separate shell)", JOIN_ADVICE]
          end
        return if problem.nil?

        raise MCPforSketchUp::Core::StructuredError.new(-32603,
          "the joint was not committed: #{problem}; the operation was rolled back and the " \
          "model is unchanged. Each board must fill its bounding box where the boards touch " \
          "(no notch, taper or L-shape), and the pocket must not meet an earlier one. #{advice}")
      end
    end
  end
end

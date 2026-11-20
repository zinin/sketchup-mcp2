# mcp_for_sketchup/mcp_for_sketchup/helpers/operation.rb
module MCPforSketchUp
  module Helpers
    # M-16: the one place a mutating handler opens, commits and aborts its
    # undo step. One call is one undo step; a call that fails leaves the
    # model as it was.
    module Operation
      # Starts the operation, runs the block and commits, returning the
      # block's value. The block builds the response itself, so the response
      # exists before commit_operation: commit has been seen to invalidate
      # the proxies of solid-operation results (operations.rb, run_edge_op).
      #
      # When the block raises — any exception, StandardError or not — and
      # when commit_operation itself raises, the operation is aborted from the
      # ensure, and the exception goes on to the caller. A block left by
      # return, break or throw skips the commit too: the operation is aborted
      # and -32603 is raised in place of the jump, since the handler would
      # otherwise answer with a success for edits that were rolled back.
      # To finish a block early, use `next value`.
      def self.run(model, label)
        model.start_operation(label, true)
        completed = false
        raised = false
        begin
          result = yield
          model.commit_operation
          completed = true
          result
        rescue Exception # rubocop:disable Lint/RescueException
          raised = true # for the ensure; the exception goes on as it is
          raise
        ensure
          unless completed
            safe_abort(model)
            raise left_early(label) unless raised
          end
        end
      end

      def self.left_early(label)
        MCPforSketchUp::Core::StructuredError.new(-32603,
          "internal error: '#{label}' left its undo step before it finished (a return, break or " \
          "throw inside Operation.run), so its changes were rolled back")
      end

      # Wrap abort_operation so its own potential exception (NoMethodError on
      # older SU, "no operation active" if double-abort) never shadows the
      # original handler exception.
      def self.safe_abort(model)
        model.abort_operation if model.respond_to?(:abort_operation)
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log("DEBUG",
          "Operation.safe_abort: model.abort_operation raised: " \
          "#{e.class}: #{e.message}")
      end
    end
  end
end

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
      # When the block does not complete — any exception, StandardError or
      # not, or a throw — and when commit_operation itself raises, the
      # operation is aborted from the ensure, and the exception goes on to
      # the caller.
      def self.run(model, label)
        model.start_operation(label, true)
        completed = false
        begin
          result = yield
          model.commit_operation
          completed = true
          result
        ensure
          safe_abort(model) unless completed
        end
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

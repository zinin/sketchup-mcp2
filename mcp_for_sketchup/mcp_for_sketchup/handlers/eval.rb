# su_mcp/su_mcp/handlers/eval.rb
module MCPforSketchUp
  module Handlers
    module Eval
      V = MCPforSketchUp::Helpers::Validation

      def self.eval_ruby(params)
        code = V.require_string(params, "code")
        binding_obj = TOPLEVEL_BINDING.dup
        result = eval(code, binding_obj)  # rubocop:disable Security/Eval
        # Return raw string so dispatch.wrap_content puts it directly into
        # text-field without nesting (Python `_call` extracts text and Claude
        # sees a plain value rather than `{"result": "..."}`).
        result.to_s
      end
    end
  end
end

# mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb
module MCPforSketchUp
  module Handlers
    module Eval
      V = MCPforSketchUp::Helpers::Validation

      # JSON-RPC application-level error code used to signal that the user
      # has not opted into Ruby evaluation. Distinct from -32603 (generic
      # internal error) so the Python wrapper can route the message to the
      # LLM as an actionable hint rather than an opaque traceback. See spec
      # §4 and Task 9.
      EVAL_DISABLED_CODE = -32010
      # Mirrored in src/sketchup_mcp/compat.py::EVAL_DISABLED_CODE (Python side).

      EVAL_DISABLED_MESSAGE = (
        "eval_ruby is disabled. Open Plugins → MCP Server → Settings... " \
        "and check 'Enable Ruby evaluation'. " \
        "WARNING: this grants the MCP server arbitrary code execution " \
        "including filesystem and shell access."
      ).freeze

      def self.eval_ruby(params)
        unless MCPforSketchUp::Core::Config.eval_enabled?
          raise MCPforSketchUp::Core::StructuredError.new(
            EVAL_DISABLED_CODE,
            EVAL_DISABLED_MESSAGE,
          )
        end
        code = V.require_string(params, "code")
        binding_obj = TOPLEVEL_BINDING.dup
        result =
          begin
            eval(code, binding_obj)  # rubocop:disable Security/Eval
          rescue MCPforSketchUp::Core::StructuredError
            # Structured-ошибки из eval'нутого кода сохраняют code/message.
            raise
          rescue NoMemoryError, SignalException
            # Process-control не глотаем: VM умирает / внешний сигнал.
            raise
          rescue Exception => e  # rubocop:disable Lint/RescueException
            # НАМЕРЕННО шире StandardError (ревью iter-1, MAJOR-4): eval'ится
            # произвольный LLM-код. SyntaxError (< ScriptError),
            # SystemStackError и даже голый `raise Exception` — не
            # StandardError: без этого arm'а они пролетают мимо всех rescue
            # в dispatch/server, запрос молча теряется и клиент висит полный
            # таймаут (60 s). SystemExit конвертируется сознательно: `exit`
            # в eval-коде не должен убивать SketchUp. Имя класса + сообщение —
            # достаточная диагностика, чтобы LLM сам починил код со следующей
            # попытки. Deep-research T-01.
            raise MCPforSketchUp::Core::StructuredError.new(
              -32603, "#{e.class}: #{e.message}"
            )
          end
        # Return raw string so dispatch.wrap_content puts it directly into
        # text-field without nesting (Python `_call` extracts text and Claude
        # sees a plain value rather than `{"result": "..."}`).
        result.to_s
      end
    end
  end
end

# mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb
require "json"

module MCPforSketchUp
  module Handlers
    module Dispatch
      # Returns response Hash (or nil for notifications). Server-loop writes only
      # if non-nil. Notifications (JSON-RPC 2.0 §4.1) carry no `id` and must NOT
      # receive a response.
      def self.handle(request)
        request_id = nil
        is_notification = false
        tool = nil
        params = {}
        begin
          validate_envelope!(request)

          request_id = request["id"]
          is_notification = !request.key?("id")
          method = request["method"]

          response_body =
            case method
            when "tools/call"
              call_params = request["params"]
              unless call_params.is_a?(Hash)
                raise Core::StructuredError.new(-32602, "tools/call requires params object")
              end
              tool = call_params["name"]
              unless tool.is_a?(String) && !tool.empty?
                raise Core::StructuredError.new(-32602, "tools/call requires non-empty 'name' string")
              end
              params = call_params["arguments"] || {}
              unless params.is_a?(Hash)
                raise Core::StructuredError.new(-32602, "tools/call 'arguments' must be an object")
              end
              call_handler(tool, params)
            else
              raise Core::StructuredError.new(-32601, "method not found: #{method}")
            end

          return nil if is_notification
          build_success_response(response_body, request_id)
        rescue Core::StructuredError => e
          Core::Logger.log_error(tool || "?", e)
          return nil if is_notification
          Core::Errors.build_error_response(e.code, e.message,
            Core::Errors.exception_to_data(e, tool || "?", params), request_id)
        rescue StandardError => e
          Core::Logger.log_error(tool || "?", e)
          return nil if is_notification
          Core::Errors.build_error_response(-32603, e.message,
            Core::Errors.exception_to_data(e, tool || "?", params), request_id)
        rescue ScriptError, SystemStackError => e
          # Belt-and-braces: SyntaxError/LoadError/SystemStackError — не
          # StandardError; без этого arm'а исключение любого БУДУЩЕГО хендлера
          # молча роняло бы ответ (клиент ждал бы полный таймаут). eval.rb
          # оборачивает свой eval сам; этот arm страхует остальные пути.
          # Остаточная экспозиция (осознанная): timer-/framing-пути server.rb
          # ловят только StandardError — не-хендлерные ScriptError туда не
          # доходят через Dispatch и остаются вне этого фикса.
          Core::Logger.log_error(tool || "?", e)
          return nil if is_notification
          Core::Errors.build_error_response(-32603, "#{e.class}: #{e.message}",
            Core::Errors.exception_to_data(e, tool || "?", params), request_id)
        end
      end

      def self.validate_envelope!(request)
        unless request.is_a?(Hash)
          raise Core::StructuredError.new(-32600, "request must be a JSON object")
        end
        unless request["jsonrpc"] == "2.0"
          raise Core::StructuredError.new(-32600, "jsonrpc must be '2.0'")
        end
        unless request["method"].is_a?(String) && !request["method"].empty?
          raise Core::StructuredError.new(-32600, "method must be a non-empty string")
        end
      end

      def self.build_success_response(result, request_id)
        {
          "jsonrpc" => "2.0",
          "result"  => wrap_content(result),
          "id"      => request_id
        }
      end

      # Wrap raw handler result into MCP-shape {content: [{type: "text", text: ...}]}.
      # `isError: false` is REQUIRED by MCP `tools/call` spec — some clients use
      # it to distinguish success from error in their UI.
      # Python `_call` extracts content[0].text and returns it as plain string.
      # Handlers returning Hash → JSON-encoded text; eval_ruby returns String → as-is.
      def self.wrap_content(result)
        text = result.is_a?(String) ? result : JSON.generate(result)
        {
          "content" => [{ "type" => "text", "text" => text }],
          "isError" => false
        }
      end

      # Wire names that never mutate the model. connection.py::_RETRY_SAFE_TOOLS
      # must stay a subset of this list (tests/test_contract.py reads both).
      READ_ONLY_TOOLS = %w[
        get_model_info list_components get_component_info find_components
        list_layers get_selection get_viewport_screenshot get_version
      ].freeze

      # M-29 (spec §7.4): the arguments each wire name's handler reads. Any
      # other argument is refused with -32602 before the handler runs, so a
      # misspelt option fails loudly instead of being ignored.
      # tests/test_contract.py checks this table against the parameters of the
      # MCP tools in tools.py, and pins the arguments only a direct client can
      # send (segments, edge_indices, width, height).
      ALLOWED_ARGS = {
        "create_component"        => %w[type position dimensions name segments],
        "delete_component"        => %w[id],
        "transform_component"     => %w[id position rotation scale],
        "set_material"            => %w[id material],
        "export"                  => %w[format width height],
        "export_scene"            => %w[format width height],
        "boolean_operation"       => %w[target_id tool_id operation delete_originals],
        "chamfer_edges"           => %w[entity_id distance edge_indices],
        "fillet_edges"            => %w[entity_id radius segments edge_indices],
        "create_mortise_tenon"    => %w[mortise_id tenon_id width height depth offset_x offset_y offset_z],
        "eval_ruby"               => %w[code],
        "get_model_info"          => %w[],
        "list_components"         => %w[recursive max_depth limit offset response_format],
        "get_component_info"      => %w[id],
        "find_components"         => %w[name layer type max_depth limit offset response_format],
        "list_layers"             => %w[],
        "create_layer"            => %w[name],
        "undo"                    => %w[],
        "get_selection"           => %w[],
        "get_viewport_screenshot" => %w[max_size view_preset zoom_extents style restore_view],
        "get_version"             => %w[],
      }.freeze

      # Names the first unknown argument in the order the client sent them. A
      # tool without an entry is left to call_handler's -32601.
      def self.check_arguments!(tool, params)
        allowed = ALLOWED_ARGS[tool]
        return if allowed.nil?
        unknown = params.keys.find { |name| !allowed.include?(name) }
        return if unknown.nil?
        raise Core::StructuredError.new(-32602, "unknown argument '#{unknown}' for #{tool}")
      end

      def self.call_handler(tool, params)
        check_arguments!(tool, params)
        case tool
        when "create_component"      then Handlers::Geometry.create_component(params)
        when "delete_component"      then Handlers::Geometry.delete_component(params)
        when "transform_component"   then Handlers::Geometry.transform_component(params)
        when "set_material"          then Handlers::Materials.set_material(params)
        when "export", "export_scene" then Handlers::Export.export(params)
        when "boolean_operation"     then Handlers::Operations.boolean_operation(params)
        when "chamfer_edges"         then Handlers::Operations.chamfer_edges(params)
        when "fillet_edges"          then Handlers::Operations.fillet_edges(params)
        when "create_mortise_tenon"  then Handlers::Joints.create_mortise_tenon(params)
        when "eval_ruby"             then Handlers::Eval.eval_ruby(params)
        when "get_model_info"        then Handlers::Model.get_model_info(params)
        when "list_components"       then Handlers::Model.list_components(params)
        when "get_component_info"    then Handlers::Model.get_component_info(params)
        when "find_components"       then Handlers::Model.find_components(params)
        when "list_layers"           then Handlers::Model.list_layers(params)
        when "create_layer"          then Handlers::Model.create_layer(params)
        when "undo"                  then Handlers::Model.undo(params)
        when "get_selection"         then Handlers::Model.get_selection(params)
        when "get_viewport_screenshot" then Handlers::View.viewport_screenshot(params)
        when "get_version"             then Handlers::System.get_version(params)
        else
          raise Core::StructuredError.new(-32601, "unknown tool: #{tool}")
        end
      end
    end
  end
end

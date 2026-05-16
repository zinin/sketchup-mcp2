# su_mcp/su_mcp/handlers/dispatch.rb
require "json"

module SU_MCP
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

          # Capture id and notification flag BEFORE the version check so:
          #  - -32001 error responses preserve the real request id
          #  - notifications (no "id") are silently dropped on mismatch
          request_id = request["id"]
          is_notification = !request.key?("id")
          method = request["method"]

          # Version handshake — diagnostic bypass for tools/call → get_version
          # (matches the actual wire format; Python NEVER sends method == "get_version").
          is_get_version_call =
            method == "tools/call" &&
            request["params"].is_a?(Hash) &&
            request.dig("params", "name") == "get_version"

          unless is_get_version_call
            Core::Compat.check_python_version(request["client_version"])
          end

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
            when "resources/list", "prompts/list"
              { "resources" => [], "prompts" => [] }
            else
              raise Core::StructuredError.new(-32601, "method not found: #{method}")
            end

          return nil if is_notification
          build_success_response(response_body, request_id)
        rescue Core::StructuredError => e
          if e.code == -32001
            Core::Logger.log("WARN",
              "tool=dispatch.version msg=client_version mismatch: #{e.message}")
          else
            Core::Logger.log_error(tool || "?", e)
          end
          return nil if is_notification
          Core::Errors.build_error_response(e.code, e.message,
            Core::Errors.exception_to_data(e, tool || "?", params), request_id)
        rescue StandardError => e
          Core::Logger.log_error(tool || "?", e)
          return nil if is_notification
          Core::Errors.build_error_response(-32603, e.message,
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

      def self.call_handler(tool, params)
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
        when "create_dovetail"       then Handlers::Joints.create_dovetail(params)
        when "create_finger_joint"   then Handlers::Joints.create_finger_joint(params)
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

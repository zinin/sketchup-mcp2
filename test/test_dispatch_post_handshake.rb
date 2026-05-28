# test/test_dispatch_post_handshake.rb — Dispatch.handle behavior after
# the one-time handshake (no per-request version check). Tests the
# post-handshake protocol surface: tools/call dispatch, unknown methods,
# malformed envelopes, notification handling. Version-handshake logic
# itself is tested in test/test_server_handshake.rb.

require "minitest/autorun"
require "json"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/system"

class TestDispatchPostHandshake < Minitest::Test
  def setup
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "INFO"
  end

  def make_request(method:, params: {}, id: 1)
    req = {
      "jsonrpc" => "2.0",
      "method"  => method,
      "params"  => params,
    }
    req["id"] = id unless id == :omit
    req
  end

  # --- happy path: tools/call without client_version ---

  def test_dispatch_tools_call_get_version_returns_payload
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      id: 42,
    )
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal 42, resp["id"]
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  # --- envelope validation ---

  def test_dispatch_rejects_non_hash_request
    resp = MCPforSketchUp::Handlers::Dispatch.handle("not a hash")
    assert_equal(-32600, resp["error"]["code"])
  end

  def test_dispatch_rejects_wrong_jsonrpc_version
    req = { "jsonrpc" => "1.0", "method" => "tools/call", "id" => 1, "params" => {} }
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32600, resp["error"]["code"])
  end

  def test_dispatch_rejects_empty_method
    req = { "jsonrpc" => "2.0", "method" => "", "id" => 1 }
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32600, resp["error"]["code"])
  end

  # --- tools/call params validation ---

  def test_dispatch_tools_call_requires_params_object
    req = make_request(method: "tools/call", params: nil, id: 1)
    req["params"] = "not a hash"
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32602, resp["error"]["code"])
  end

  def test_dispatch_tools_call_requires_non_empty_name
    req = make_request(method: "tools/call", params: { "name" => "", "arguments" => {} }, id: 1)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32602, resp["error"]["code"])
  end

  def test_dispatch_unknown_tool_returns_method_not_found
    req = make_request(method: "tools/call",
      params: { "name" => "no_such_tool", "arguments" => {} }, id: 1)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
    assert_includes resp["error"]["message"], "unknown tool"
  end

  # --- removed dormant branches: prompts/list, resources/list ---

  def test_dispatch_prompts_list_returns_method_not_found
    req = make_request(method: "prompts/list", id: 1)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
  end

  def test_dispatch_resources_list_returns_method_not_found
    req = make_request(method: "resources/list", id: 1)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_equal(-32601, resp["error"]["code"])
  end

  # --- notifications (no id) return nil ---

  def test_dispatch_notification_returns_nil
    req = make_request(method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      id: :omit)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    assert_nil resp
  end

  # --- no client_version expected, no server_version added by Dispatch ---

  def test_dispatch_response_has_no_server_version_key
    req = make_request(method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} }, id: 1)
    resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
    # server_version is no longer injected per-request — it's delivered once
    # in Server#handle_pre_handshake's hello reply. Dispatch returns a pure
    # JSON-RPC envelope with no version field.
    refute resp.key?("server_version"),
      "Dispatch must not embed server_version; that lives in Server now"
  end
end

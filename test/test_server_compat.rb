# test/test_server_compat.rb — server-side version-handshake integration tests.
# Uses REAL Dispatch.handle + REAL Core::Server with a fake socket (no
# method-overriding double — production code is actually exercised).

require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/server"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"

class TestServerCompat < Minitest::Test
  PYTHON = SU_MCP::Core::Compat::MIN_PYTHON  # current matched value "0.0.3"

  def setup
    # Logger.log_error reads Config.log_level/level_value — initialize the
    # accessors so logging during the rescue path doesn't blow up with
    # NoMethodError("nil:NilClass"). Match production defaults.
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "INFO"
  end

  def make_request(method:, params: {}, client_version: PYTHON, id: 1)
    req = {
      "jsonrpc" => "2.0",
      "method"  => method,
      "params"  => params,
    }
    req["id"] = id unless id == :omit
    req["client_version"] = client_version unless client_version == :omit
    req
  end

  # -------- Dispatch.handle: client_version check --------

  def test_dispatch_with_valid_client_version_returns_id
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      client_version: PYTHON, id: 42,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal 42, resp["id"]
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  def test_dispatch_incompatible_client_version_preserves_request_id
    # Regression for the request_id=nil bug found in iter-1 review:
    # the check must run AFTER request_id is captured.
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: "0.0.0",
      id: 42,
    )
    # MIN_PYTHON is "0.0.3" by default; 0.0.0 is too old.
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["error"]
    assert_equal 42, resp["id"], "id must be preserved on -32001"
    assert_equal(-32001, resp["error"]["code"])
    assert_includes resp["error"]["message"], "too old"
  end

  def test_dispatch_get_version_bypasses_client_version_check
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      client_version: "0.0.0",  # would normally trip the check
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  def test_dispatch_missing_client_version_treated_as_pre_0_1_0
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: :omit,
      id: 7,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["error"]
    assert_equal 7, resp["id"]
    assert_equal(-32001, resp["error"]["code"])
    assert_includes resp["error"]["message"], "pre-dates"
  end

  def test_dispatch_notification_with_mismatch_silently_dropped
    # JSON-RPC 2.0: server MUST NOT reply to a notification (no id).
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: "0.0.0",
      id: :omit,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_nil resp, "notification with mismatch must return nil (no response)"
  end

  # -------- Core::Server.encode_response_body: server_version on every envelope --------

  def encode(response)
    # Build a real Server, drive the real encode_response_body via send.
    server = SU_MCP::Core::Server.new
    server.send(:encode_response_body, response)
  end

  def test_encode_response_body_injects_server_version_on_success
    body = encode({ "jsonrpc" => "2.0", "id" => 1, "result" => { "k" => "v" } })
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"]
  end

  def test_encode_response_body_injects_server_version_on_error
    body = encode({
      "jsonrpc" => "2.0", "id" => 2,
      "error" => { "code" => -32000, "message" => "boom", "data" => {} },
    })
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"]
    assert_equal(-32000, payload["error"]["code"])
  end

  def test_encode_response_body_injects_server_version_on_json_generator_fallback
    # Force JSON.generate to fail on the first call; fallback envelope
    # must still carry server_version.
    #
    # NOTE: Float::NAN reliably raises JSON::GeneratorError ("NaN not
    # allowed in JSON"). Object.new does NOT — JSON.generate falls back
    # to inspecting it as a string and produces valid JSON.
    server = SU_MCP::Core::Server.new
    bad_response = {
      "jsonrpc" => "2.0", "id" => 9,
      "result" => Float::NAN,  # raises JSON::GeneratorError
    }
    body = server.send(:encode_response_body, bad_response)
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"],
      "fallback envelope must carry server_version"
    assert payload.key?("error"), "fallback must be an error envelope"
  end
end

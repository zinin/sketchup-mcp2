# test/test_system.rb — get_version handler unit + dispatch routing test.

require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"

class TestSystem < Minitest::Test
  def test_get_version_returns_compat_metadata
    result = SU_MCP::Handlers::System.get_version(nil)
    assert_kind_of Hash, result
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION,    result[:ruby_version]
    assert_equal SU_MCP::Core::Compat::MIN_PYTHON,      result[:min_compatible_python]
    assert_equal SU_MCP::Core::Compat::MAX_PYTHON,      result[:max_compatible_python]
  end

  def test_get_version_ignores_params
    result = SU_MCP::Handlers::System.get_version({ "foo" => "bar" })
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, result[:ruby_version]
  end

  def test_dispatch_routes_get_version_to_system
    req = {
      "jsonrpc" => "2.0",
      "method"  => "tools/call",
      "params"  => { "name" => "get_version", "arguments" => {} },
      "id"      => 7,
      "client_version" => SU_MCP::Core::Compat::MIN_PYTHON,
    }
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["result"]
    text = resp["result"]["content"][0]["text"]
    payload = JSON.parse(text)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["ruby_version"]
  end
end

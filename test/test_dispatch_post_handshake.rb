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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/eval"

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

  # --- eval_ruby gate (warehouse compliance) ---
  # Iter-1 CRITICAL-8: `saved_eval` is a local var (lowercase). An uppercase
  # name would be parsed as a constant — Ruby raises `dynamic constant
  # assignment` inside method bodies — so this local must stay lowercase.

  def test_eval_ruby_returns_32010_when_disabled
    saved_eval = MCPforSketchUp::Core::Config.eval_enabled
    MCPforSketchUp::Core::Config.eval_enabled = false
    begin
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "1+1" } },
        id: 99,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      assert_equal 99, resp["id"]
      refute_nil resp["error"], "expected error envelope when eval disabled"
      assert_equal(-32010, resp["error"]["code"])
      assert_match(/disabled/i, resp["error"]["message"])
      assert_match(/Settings/, resp["error"]["message"])
    ensure
      MCPforSketchUp::Core::Config.eval_enabled = saved_eval
    end
  end

  def test_eval_ruby_succeeds_when_enabled
    saved_eval = MCPforSketchUp::Core::Config.eval_enabled
    MCPforSketchUp::Core::Config.eval_enabled = true
    begin
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "21*2" } },
        id: 100,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      assert_equal 100, resp["id"]
      refute resp.key?("error"), "expected no error when eval enabled"
      text = resp.dig("result", "content", 0, "text")
      assert_equal "42", text
    ensure
      MCPforSketchUp::Core::Config.eval_enabled = saved_eval
    end
  end

  # --- T-01: не-StandardError исключения обязаны давать error-ответ ---
  # SyntaxError < ScriptError (НЕ StandardError) — до фикса пролетал мимо
  # всех rescue и запрос молча терялся (клиент ждал полный 60 s таймаут).

  def test_eval_ruby_syntax_error_returns_structured_error_fast
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "def broken(" } },
        id: 101,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp, "syntax error must produce an error envelope, not a dropped request"
      assert_equal 101, resp["id"]
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/SyntaxError/, resp["error"]["message"])
    end
  end

  def test_eval_ruby_runtime_error_message_includes_class
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby", "arguments" => { "code" => "raise 'boom'" } },
        id: 102,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/RuntimeError: boom/, resp["error"]["message"])
    end
  end

  def test_eval_ruby_stack_overflow_returns_structured_error
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby",
                  # Самозацикленная lambda: SystemStackError без определения
                  # глобального метода (не мусорим в shared-process сьюте).
                  # Поведение специфично для MRI (SketchUp = MRI 3.2); на
                  # JRuby/TruffleRuby стек-переполнение ведёт себя иначе.
                  "arguments" => { "code" => "f = nil; f = -> { f.call }; f.call" } },
        id: 103,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/SystemStackError/, resp["error"]["message"])
    end
  end

  def test_eval_ruby_bare_exception_subclass_returns_structured_error
    with_eval_enabled do
      req = make_request(
        method: "tools/call",
        params: { "name" => "eval_ruby",
                  # Не StandardError и не ScriptError: LLM-код так пишет
                  # регулярно (питоний рефлекс raise Exception(...)).
                  "arguments" => { "code" => "raise Exception, 'raw boom'" } },
        id: 105,
      )
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp, "bare Exception must produce an error envelope"
      assert_equal 105, resp["id"]
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/Exception: raw boom/, resp["error"]["message"])
    end
  end

  def test_dispatch_returns_error_envelope_for_script_error_from_any_handler
    sys = MCPforSketchUp::Handlers::System
    original = sys.method(:get_version)
    sys.define_singleton_method(:get_version) { |_params| raise ScriptError, "handler exploded" }
    begin
      req = make_request(method: "tools/call",
        params: { "name" => "get_version", "arguments" => {} }, id: 104)
      resp = MCPforSketchUp::Handlers::Dispatch.handle(req)
      refute_nil resp, "ScriptError from a handler must not drop the response"
      assert_equal 104, resp["id"]
      assert_equal(-32603, resp["error"]["code"])
      assert_match(/handler exploded/, resp["error"]["message"])
    ensure
      sys.define_singleton_method(:get_version, original)
    end
  end

  # ---------- T-23.3: error-path dispatch (StandardError) ----------
  # ScriptError-arm уже запинен test_dispatch_returns_error_envelope_for_
  # script_error_from_any_handler — здесь только непокрытый StandardError.

  def test_handler_standard_error_becomes_minus_32603_with_id
    sys = MCPforSketchUp::Handlers::System
    original = sys.method(:get_version)
    sys.define_singleton_method(:get_version) { |_params| raise "handler exploded" }
    begin
      resp = MCPforSketchUp::Handlers::Dispatch.handle(
        "jsonrpc" => "2.0", "method" => "tools/call",
        "params" => { "name" => "get_version", "arguments" => {} }, "id" => 7)
      assert_equal(-32603, resp["error"]["code"])
      assert_includes resp["error"]["message"], "handler exploded"
      assert_equal 7, resp["id"], "id обязан пережить error-path (matching на клиенте)"
    ensure
      sys.define_singleton_method(:get_version, original)
    end
  end

  private

  def with_eval_enabled
    saved_eval = MCPforSketchUp::Core::Config.eval_enabled
    MCPforSketchUp::Core::Config.eval_enabled = true
    yield
  ensure
    MCPforSketchUp::Core::Config.eval_enabled = saved_eval
  end
end

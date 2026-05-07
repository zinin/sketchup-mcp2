# test/test_errors.rb
require "minitest/autorun"
require "json"
require "time"
require_relative "../su_mcp/su_mcp/core/errors"

class TestStructuredError < Minitest::Test
  E = SU_MCP::Core::StructuredError

  def test_stores_code_message_data
    err = E.new(-32602, "bad", { "x" => 1 })
    assert_equal(-32602, err.code)
    assert_equal "bad", err.message
    assert_equal({ "x" => 1 }, err.data)
  end

  def test_default_data_is_empty_hash
    err = E.new(-32603, "bad")
    assert_equal({}, err.data)
  end

  def test_is_a_standard_error
    err = E.new(-32603, "bad")
    assert_kind_of StandardError, err
  end
end

class TestBuildErrorResponse < Minitest::Test
  def test_shape
    resp = SU_MCP::Core::Errors.build_error_response(-32602, "bad", { "tool" => "x" }, 7)
    assert_equal "2.0", resp["jsonrpc"]
    assert_equal(-32602, resp["error"]["code"])
    assert_equal "bad", resp["error"]["message"]
    assert_equal({ "tool" => "x" }, resp["error"]["data"])
    assert_equal 7, resp["id"]
  end

  def test_null_request_id
    resp = SU_MCP::Core::Errors.build_error_response(-32700, "p", {}, nil)
    assert_nil resp["id"]
  end
end

class TestExceptionToData < Minitest::Test
  def test_includes_all_fields
    e = StandardError.new("boom")
    e.set_backtrace(["a.rb:1:in `f'", "b.rb:2:in `g'", "c.rb:3:in `h'", "d.rb:4:in `i'"])
    data = SU_MCP::Core::Errors.exception_to_data(e, "create_component", { "x" => 1 })
    assert_equal "create_component", data["tool"]
    assert_equal({ "x" => 1 }, data["params"])
    refute_nil data["timestamp"]
    assert_equal 3, data["backtrace"].length
  end

  def test_backtrace_truncated_to_3_lines
    e = RuntimeError.new("x")
    e.set_backtrace((1..10).map { |i| "frame#{i}.rb:#{i}" })
    data = SU_MCP::Core::Errors.exception_to_data(e, "t", {})
    assert_equal ["frame1.rb:1", "frame2.rb:2", "frame3.rb:3"], data["backtrace"]
  end

  def test_nil_backtrace_handled
    e = RuntimeError.new("no bt")  # backtrace defaults to nil until raised
    data = SU_MCP::Core::Errors.exception_to_data(e, "t", {})
    assert_equal [], data["backtrace"]
  end

  def test_timestamp_is_iso8601_utc
    e = StandardError.new("x")
    data = SU_MCP::Core::Errors.exception_to_data(e, "t", {})
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, data["timestamp"])
  end
end

class TestTruncateParams < Minitest::Test
  def test_short_params_pass_through
    params = { "x" => 1, "y" => 2 }
    assert_equal params, SU_MCP::Core::Errors.truncate_params(params)
  end

  def test_long_params_become_truncated_marker
    big = { "code" => "x" * 1000 }
    result = SU_MCP::Core::Errors.truncate_params(big)
    assert result.key?("_truncated"), "expected _truncated key, got #{result.keys.inspect}"
    assert_includes result["_truncated"], "...<truncated>"
    assert result["_truncated"].bytesize < 600
  end

  def test_multibyte_truncation_safe
    # 200 русских букв ≈ 400 байт UTF-8; 200 ASCII = 200 байт. Чтобы заведомо
    # превысить 512 — берём 300 кириллических.
    big = { "v" => "ё" * 300 }
    result = SU_MCP::Core::Errors.truncate_params(big)
    assert result["_truncated"].valid_encoding?, "truncated string broke UTF-8"
  end
end

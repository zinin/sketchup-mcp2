# test/test_dispatch_strict_args.rb
# M-29 (spec §7.4): a tool takes only the arguments it knows.
#
# Dispatch::ALLOWED_ARGS lists, for every wire name call_handler routes, the
# argument names its handler reads. An argument outside the list is refused
# with -32602 before the handler runs, so a misspelt option fails loudly
# instead of being ignored. tests/test_contract.py checks the table against
# the parameters of the MCP tools in tools.py.
require "minitest/autorun"

require_relative "support/dispatch_table"
require_relative "support/singleton_stubs"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"

# The module whose method test_allowed_arguments_reach_the_handler stubs, when
# handlers/geometry.rb is not loaded (a standalone run).
module MCPforSketchUp
  module Handlers
    module Geometry; end unless defined?(Geometry)
  end
end

class TestDispatchStrictArgs < Minitest::Test
  include SingletonStubs

  Dispatch = MCPforSketchUp::Handlers::Dispatch
  SE = MCPforSketchUp::Core::StructuredError

  def test_every_routed_wire_name_has_an_entry
    routed = DispatchTable.routes.flat_map(&:first).sort
    refute_empty routed
    assert_equal routed, Dispatch::ALLOWED_ARGS.keys.sort
  end

  def test_unknown_argument_is_refused
    err = assert_raises(SE) do
      Dispatch.call_handler("delete_component", { "id" => "1", "colour" => "red" })
    end
    assert_equal(-32602, err.code)
    assert_equal "unknown argument 'colour' for delete_component", err.message
  end

  def test_the_first_unknown_argument_is_named
    err = assert_raises(SE) { Dispatch.call_handler("get_version", { "b" => 1, "a" => 2 }) }
    assert_equal "unknown argument 'b' for get_version", err.message
  end

  def test_allowed_arguments_reach_the_handler
    received = []
    stub_singleton(MCPforSketchUp::Handlers::Geometry, :delete_component) { |params| received << params; :done }
    assert_equal :done, Dispatch.call_handler("delete_component", { "id" => "1" })
    assert_equal [{ "id" => "1" }], received
  end

  def test_unknown_tool_is_still_minus_32601
    err = assert_raises(SE) { Dispatch.call_handler("no_such_tool", { "x" => 1 }) }
    assert_equal(-32601, err.code)
  end
end

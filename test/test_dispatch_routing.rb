# test/test_dispatch_routing.rb
# M-09: every wire name in Dispatch.call_handler reaches the handler method
# its `when` row names.
#
# Nothing else exercises the table itself: a row with a mistyped module or
# method name, or one that drops its params, fails only when a client sends
# that wire name. The table is read from dispatch.rb as text and each wire
# name becomes a test (ROUTES), so a new row is covered without touching this
# file. A test replaces the row's handler method with a recording stub,
# dispatches the wire name and expects one call that got the params object. The
# method must exist before it is stubbed, which is why every handler file is
# loaded. The Python half of the contract, which wire names tools.py sends and
# which of them may be retried, is tests/test_contract.py.
#
# The handlers load on the first test, not when this file does (load_handlers).
# view.rb builds PRESET_DIR from Geom::Vector3d the moment it loads, and
# test_view.rb defines its own Geom stubs in a block that an existing
# Geom::Vector3d skips, so under run_all this file must not be the one to
# define the class. By the time a test runs every file has loaded, and
# test_view.rb has loaded view.rb with its stub.
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"

class TestDispatchRouting < Minitest::Test
  include SingletonStubs

  H = MCPforSketchUp::Handlers
  Dispatch = H::Dispatch

  HANDLER_DIR = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/handlers", __dir__)

  DISPATCH_SOURCE = File.read(File.join(HANDLER_DIR, "dispatch.rb"), encoding: "UTF-8")

  # The text of call_handler's `case tool` table, from `case tool` to `else`.
  TABLE = DISPATCH_SOURCE[/def self\.call_handler\b.*?\bcase tool\b(.*?)^\s*else\b/m, 1].to_s

  # [wire names, handler module name, method name] for each `when ... then` row.
  ROUTES = TABLE.scan(/^\s*when\s+(.+?)\s+then\s+Handlers::(\w+)\.(\w+)\(params\)/)
                .map { |names, mod, meth| [names.scan(/"([^"]+)"/).flatten, mod, meth] }
                .freeze

  # Loads every handler file, once. Only view.rb needs a SketchUp class at
  # load time; when nothing has defined Geom::Vector3d yet (this file run on
  # its own) a class that takes any arguments is enough for it.
  def self.load_handlers
    return if @handlers_loaded

    unless defined?(::Geom::Vector3d)
      Object.const_set(:Geom, Module.new) unless defined?(::Geom)
      ::Geom.const_set(:Vector3d, Class.new { def initialize(*); end })
    end
    Dir[File.join(HANDLER_DIR, "*.rb")].sort.each do |path|
      require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/#{File.basename(path, '.rb')}"
    end
    @handlers_loaded = true
  end

  def setup
    self.class.load_handlers
  end

  ROUTES.each do |wires, module_name, method_name|
    wires.each do |wire|
      define_method("test_#{wire}_is_routed_to_#{module_name}_#{method_name}") do
        handler = H.const_get(module_name, false)
        assert_respond_to handler, method_name,
          "dispatch.rb routes #{wire} to #{handler}.#{method_name}, which is not defined"
        calls = []
        # A one-parameter body also makes the stub refuse any other arity.
        stub_singleton(handler, method_name) { |received| calls << received }
        params = {}

        Dispatch.call_handler(wire, params)

        assert_equal 1, calls.size, "#{wire} must call #{handler}.#{method_name} once"
        assert_same params, calls.first,
          "#{wire} must pass its params on to #{handler}.#{method_name}"
      end
    end
  end

  # Without this a table that stops parsing yields no route tests and passes.
  def test_the_table_is_found_and_every_row_is_parsed
    refute_empty TABLE, "call_handler's `case tool` table not found in dispatch.rb"
    assert_equal TABLE.scan(/^\s*when\b/).size, ROUTES.size,
      "a `when` row does not read: when \"wire\" then Handlers::Module.method(params)"
    assert_equal TABLE.scan(/"[^"]*"/).size, ROUTES.sum { |wires, *| wires.size },
      "a quoted wire name sits outside the `when` lists that were parsed"
  end

  def test_read_only_tools_are_routed
    routed = ROUTES.flat_map { |wires, *| wires }

    assert_empty Dispatch::READ_ONLY_TOOLS - routed,
      "READ_ONLY_TOOLS names a wire name that call_handler does not route"
  end

  def test_an_unknown_tool_is_method_not_found
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      Dispatch.call_handler("no_such_tool", {})
    end

    assert_equal(-32601, err.code)
  end
end

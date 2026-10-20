# test/support/dispatch_table.rb
# The routing table of Handlers::Dispatch.call_handler, read from dispatch.rb
# as text. Two files need it and neither can take it from the loaded class: the
# routing test turns every row into a test, and the wire-contract harness
# (test/contract/echo_server.rb) replaces the handlers a row names before
# dispatch.rb could reach the real ones. They read it the same way, here.
#
# A row is one line: `when "wire", "alias" then Handlers::Module.method(params)`.
module DispatchTable
  DISPATCH_RB = File.expand_path(
    "../../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb", __dir__)

  # The text of call_handler's `case tool` table, from `case tool` to `else`;
  # empty when dispatch.rb has no such table.
  def self.table(path = DISPATCH_RB)
    File.read(path, encoding: "UTF-8")[/def self\.call_handler\b.*?\bcase tool\b(.*?)^\s*else\b/m, 1].to_s
  end

  # [wire names, handler module name, method name] for each `when ... then` row
  # of `table_text`.
  def self.routes(table_text = table)
    table_text.scan(/^\s*when\s+(.+?)\s+then\s+Handlers::(\w+)\.(\w+)\(params\)/)
              .map { |names, mod, meth| [names.scan(/"([^"]+)"/).flatten, mod, meth] }
  end
end

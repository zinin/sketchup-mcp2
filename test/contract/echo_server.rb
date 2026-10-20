# test/contract/echo_server.rb
# M-09: the real Ruby server for tests/test_contract_wire.py, with an echo in
# place of every handler.
#
# Loads core/ (all but application.rb) and handlers/dispatch.rb without
# SketchUp and serves them on a real TCP socket. Every module that
# Dispatch.call_handler routes to becomes an echo module; the routes are read
# from dispatch.rb as text, the way test/test_dispatch_routing.rb reads them.
# An echo method prints one line,
# {"handler": "<Module>.<method>", "params": {...}}, and returns
# {"echo" => true}. The real handler files are never loaded, so nothing calls
# the SketchUp API. ::UI.start_timer only records the server's tick, and the
# loop at the bottom fires it once per Server::TIMER_INTERVAL.
#
# stdout carries the protocol and nothing else: first `PORT <n>`, the port the
# OS picked for Config.port = 0, then one JSON line per handler call. Logger
# output goes to stderr. The process exits when stdin closes, so it cannot
# outlive the test that started it.
#
# Not a test file: test/run_all.rb and the Rakefile load only test/test_*.rb.
require "json"

# Logger writes to $stdout when there is no SketchUp console. Pointing $stdout
# at stderr keeps its lines, and any stray puts, out of the protocol.
PROTOCOL = STDOUT
PROTOCOL.sync = true
$stdout = $stderr

PLUGIN_DIR = File.expand_path("../../mcp_for_sketchup/mcp_for_sketchup", __dir__)

%w[
  core/errors core/compat core/config core/logger core/framing
  core/client_state core/server handlers/dispatch
].each { |path| require File.join(PLUGIN_DIR, path) }

# The part of SketchUp's UI module that Core::Server#start and #stop call.
# The server starts one repeating timer; its block runs whenever the loop at
# the bottom calls fire_timers.
module UI
  @timers  = {}
  @last_id = 0

  def self.start_timer(_seconds, _repeat, &block)
    @last_id += 1
    @timers[@last_id] = block
    @last_id
  end

  def self.stop_timer(id)
    @timers.delete(id)
  end

  def self.fire_timers
    @timers.values.each(&:call)
  end
end

DISPATCH_RB = File.join(PLUGIN_DIR, "handlers", "dispatch.rb")
# [module name, method name] for each Handlers::<Module>.<method>(params) in
# call_handler's `case tool` table.
ROUTES = File.read(DISPATCH_RB, encoding: "UTF-8")[/def self\.call_handler\b.*?\bcase tool\b(.*?)^\s*else\b/m, 1]
             .to_s.scan(/\bHandlers::(\w+)\.(\w+)\(params\)/).uniq
abort "echo_server: no Handlers::<Module>.<method>(params) in #{DISPATCH_RB}" if ROUTES.empty?

ROUTES.group_by(&:first).each do |module_name, routes|
  echo = Module.new
  routes.each do |_, method_name|
    echo.define_singleton_method(method_name) do |params|
      PROTOCOL.puts(JSON.generate("handler" => "#{module_name}.#{method_name}",
                                  "params"  => params))
      { "echo" => true }
    end
  end
  MCPforSketchUp::Handlers.const_set(module_name, echo)
end

# True once stdin is at EOF. Anything written to stdin is read and dropped.
def stdin_closed?
  $stdin.read_nonblock(4096)
  false
rescue IO::WaitReadable
  false
rescue EOFError
  true
end

config = MCPforSketchUp::Core::Config
config.host      = "127.0.0.1"
config.port      = 0
# INFO, not the plugin's WARN: a rejected handshake is logged at INFO, and the
# connect/handshake trail is what a failing run needs on stderr.
config.log_level = "INFO"

server = MCPforSketchUp::Core::Server.new
server.start
PROTOCOL.puts("PORT #{server.instance_variable_get(:@server).addr[1]}")

# One server tick per TIMER_INTERVAL, as SketchUp's timer fires it, until
# stdin closes.
until IO.select([$stdin], nil, nil, MCPforSketchUp::Core::Server::TIMER_INTERVAL) &&
      stdin_closed?
  UI.fire_timers
end
server.stop

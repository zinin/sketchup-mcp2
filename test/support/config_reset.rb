# test/support/config_reset.rb
# Shared helper: nil out every module-level Config accessor between tests
# so global state does not leak across test files.
module ConfigReset
  def self.reset_all!
    c = MCPforSketchUp::Core::Config
    c.host           = nil
    c.port           = nil
    c.log_level      = nil
    c.eval_enabled   = nil
    c.log_to_file    = nil
    c.log_file_path  = nil
  end
end

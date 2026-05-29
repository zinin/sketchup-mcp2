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
    # Logger's one-shot log-file-failure flag is module-global state too: clear
    # it between tests so a write failure in one test cannot suppress the
    # fallback notice expected by another (test_logger). Guarded because
    # test_config requires only config.rb, not core/logger.
    if MCPforSketchUp::Core.const_defined?(:Logger)
      MCPforSketchUp::Core::Logger.instance_variable_set(:@log_file_write_failed, false)
    end
  end
end

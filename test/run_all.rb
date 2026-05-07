# test/run_all.rb
# Entry point for Ruby unit tests. Each test file is independent and may also
# be run directly via `ruby test/test_<name>.rb`.

require "minitest/autorun"

Dir[File.join(__dir__, "test_*.rb")].sort.each { |f| require_relative File.basename(f, ".rb") }

# test/test_config_token.rb
# M-06 (spec §7.1): the plugin's MCP token in SketchUp's preferences.
#
# Config.load_token! runs once when the plugin loads. It keeps a valid saved
# token and replaces a missing or malformed one with a new token, which it
# saves; when the save fails, the token still serves this session.
# Config.regenerate_token! (Settings → Regenerate) saves a new token before it
# takes effect, so a failed save keeps the old one. The token never reaches a
# log line.
#
# A file of its own: test_config.rb loads config.rb alone, and these tests need
# the logger, whose calls they record. Fakes: TokenStore answers
# read_default / write_default for the token key and records the writes;
# Core::Logger.log is stubbed per test (SingletonStubs).
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "support/auth_vectors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/auth"
require_relative "support/config_reset"

class TestConfigToken < Minitest::Test
  include SingletonStubs

  C = MCPforSketchUp::Core::Config
  HEX64 = /\A[0-9a-f]{64}\z/

  class TokenStore
    attr_reader :writes

    def initialize(saved: nil, saves: true)
      @saved = saved
      @saves = saves
      @writes = []
    end

    def read_default(_section, key, default)
      key == "auth_token" && !@saved.nil? ? @saved : default
    end

    def write_default(section, key, value)
      @writes << [section, key, value]
      @saves
    end
  end

  def setup
    ConfigReset.reset_all!
    @logged = []
    logged = @logged
    stub_singleton(MCPforSketchUp::Core::Logger, :log) { |level, msg| logged << [level, msg] }
  end

  def warnings
    @logged.select { |level, _| level == "WARN" }.map(&:last)
  end

  def test_load_token_creates_and_saves_a_token
    store = TokenStore.new
    token = C.load_token!(store)
    assert_match HEX64, token
    assert_equal token, C.token
    assert_equal [["MCPforSketchUp", "auth_token", token]], store.writes
    assert_empty warnings, "a first start is not a warning"
  end

  def test_load_token_keeps_a_valid_stored_token
    store = TokenStore.new(saved: AuthVectors::TOKEN)
    assert_equal AuthVectors::TOKEN, C.load_token!(store)
    assert_equal AuthVectors::TOKEN, C.token
    assert_empty store.writes
  end

  def test_load_token_replaces_a_malformed_stored_token
    store = TokenStore.new(saved: "x" * 10)
    token = C.load_token!(store)
    assert_match HEX64, token
    assert_equal [["MCPforSketchUp", "auth_token", token]], store.writes
    assert_equal 1, warnings.length
    assert_includes warnings[0], "auth_token"
    refute_includes warnings[0], "x" * 10
    refute_includes warnings[0], token
  end

  def test_load_token_keeps_the_token_when_saving_fails
    store = TokenStore.new(saves: false)
    token = C.load_token!(store)
    assert_match HEX64, token
    assert_equal token, C.token
    assert_equal 1, warnings.length
    assert_includes warnings[0], "could not save the MCP token"
    refute_includes warnings[0], token
  end

  def test_regenerate_token_saves_a_new_token
    C.token = AuthVectors::TOKEN
    store = TokenStore.new
    token = C.regenerate_token!(store)
    assert_match HEX64, token
    refute_equal AuthVectors::TOKEN, token
    assert_equal token, C.token
    assert_equal [["MCPforSketchUp", "auth_token", token]], store.writes
  end

  def test_regenerate_token_keeps_the_old_token_when_saving_fails
    C.token = AuthVectors::TOKEN
    store = TokenStore.new(saves: false)
    assert_raises(RuntimeError) { C.regenerate_token!(store) }
    assert_equal AuthVectors::TOKEN, C.token
  end
end

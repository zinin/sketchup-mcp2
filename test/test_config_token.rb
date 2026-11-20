# test/test_config_token.rb
# M-06 (spec §7.1): the plugin's MCP token, in a file of its own.
#
# Config.load_token! runs once when the plugin loads. It keeps a valid token
# from the file and replaces a missing or malformed one with a new token, which
# it writes; when the write fails, the token still serves this session.
# Config.regenerate_token! (Settings → Regenerate) writes a new token before it
# takes effect, so a failed write keeps the old one. The token never reaches a
# log line.
#
# Not SketchUp's preferences (Task 11): SketchUp writes them to disk only when
# it closes normally, so after a crash a regenerated token gave way to the old
# one. The file is written at once: a temporary file, flushed, then renamed.
#
# A file of its own: test_config.rb loads config.rb alone, and these tests need
# the logger, whose calls they record (Core::Logger.log is stubbed per test).
require "minitest/autorun"
require "tmpdir"
require "fileutils"

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

  def setup
    ConfigReset.reset_all!
    @dir  = Dir.mktmpdir("mcp-token")
    @path = File.join(@dir, "MCPforSketchUp", "auth_token")
    @logged = []
    logged = @logged
    stub_singleton(MCPforSketchUp::Core::Logger, :log) { |level, msg| logged << [level, msg] }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def warnings
    @logged.select { |level, _| level == "WARN" }.map(&:last)
  end

  def temporary_files
    Dir.glob("#{@path}*.tmp")
  end

  def write(text)
    FileUtils.mkdir_p(File.dirname(@path))
    File.binwrite(@path, text)
  end

  def test_load_token_creates_and_writes_a_token
    token = C.load_token!(@path)
    assert_match HEX64, token
    assert_equal token, C.token
    assert_equal token, File.binread(@path)
    assert_empty warnings, "a first start is not a warning"
  end

  def test_load_token_keeps_a_valid_token
    write("#{AuthVectors::TOKEN}\n")
    assert_equal AuthVectors::TOKEN, C.load_token!(@path)
    assert_equal AuthVectors::TOKEN, C.token
    assert_equal "#{AuthVectors::TOKEN}\n", File.binread(@path), "a kept token is not rewritten"
    assert_empty warnings
  end

  def test_load_token_replaces_a_malformed_token
    write("x" * 10)
    token = C.load_token!(@path)
    assert_match HEX64, token
    assert_equal token, File.binread(@path)
    assert_equal 1, warnings.length
    assert_includes warnings[0], @path
    refute_includes warnings[0], "x" * 10
    refute_includes warnings[0], token
  end

  def test_load_token_keeps_the_token_when_writing_fails
    File.write(File.join(@dir, "MCPforSketchUp"), "a file where the directory should be")
    token = C.load_token!(@path)
    assert_match HEX64, token
    assert_equal token, C.token
    assert_equal 1, warnings.length
    assert_includes warnings[0], "could not save the MCP token"
    refute_includes warnings[0], token
  end

  # A read error is not a missing file: the stored token may be fine, so this
  # session gets a new one and the entry stays as it was.
  def test_load_token_leaves_an_entry_it_cannot_read
    FileUtils.mkdir_p(@path)
    token = C.load_token!(@path)
    assert_match HEX64, token
    assert File.directory?(@path)
    assert_equal 1, warnings.length
    assert_includes warnings[0], "could not read the MCP token"
  end

  def test_regenerate_token_writes_the_new_token_before_it_takes_effect
    write(AuthVectors::TOKEN)
    C.token = AuthVectors::TOKEN
    token = C.regenerate_token!(@path)
    assert_match HEX64, token
    refute_equal AuthVectors::TOKEN, token
    assert_equal token, C.token
    assert_equal token, File.binread(@path)
    assert_empty temporary_files, "no temporary file is left"
  end

  def test_regenerate_token_keeps_the_old_token_when_writing_fails
    write(AuthVectors::TOKEN)
    C.token = AuthVectors::TOKEN
    stub_singleton(File, :rename) { |*_| raise Errno::EACCES, "rename" }
    assert_raises(Errno::EACCES) { C.regenerate_token!(@path) }
    assert_equal AuthVectors::TOKEN, C.token
    assert_equal AuthVectors::TOKEN, File.binread(@path), "the file still holds the old token"
    assert_empty temporary_files, "no temporary file is left"
  end

  # Codex review (PR #23): SketchUp processes of one user share the file. With
  # one fixed temporary name, two writers truncated each other's file, and one
  # renamed the other's token into place. Each write has a file of its own,
  # and removes only that one.
  def test_each_write_uses_a_temporary_file_of_its_own
    sources = []
    rename = File.method(:rename)
    stub_singleton(File, :rename) { |from, to| sources << from; rename.call(from, to) }
    C.regenerate_token!(@path)
    C.regenerate_token!(@path)
    assert_equal 2, sources.uniq.length
    assert_empty temporary_files
  end

  def test_a_write_leaves_another_writers_temporary_file
    write(AuthVectors::TOKEN)
    other = "#{@path}.4242.0a1b2c3d.tmp"
    File.binwrite(other, "being written by another SketchUp")
    C.regenerate_token!(@path)
    assert File.exist?(other)
  end

  # Two first starts at once must not each make a token: one would be gone at
  # the next start. The read and the write happen under a lock, so the second
  # start reads the token the first one wrote.
  def test_load_token_waits_for_a_writer_holding_the_lock
    FileUtils.mkdir_p(File.dirname(@path))
    locked = Queue.new
    holder = Thread.new do
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        locked << true
        sleep 0.2
        File.binwrite(@path, AuthVectors::TOKEN)
      end
    end
    locked.pop
    assert_equal AuthVectors::TOKEN, C.load_token!(@path)
    holder.join
    assert_equal AuthVectors::TOKEN, File.binread(@path)
  end

  def test_the_token_file_is_private
    skip "POSIX modes" if Gem.win_platform?
    C.load_token!(@path)
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777
  end

  def test_token_path_follows_the_platform
    assert_equal "C:/Users/u/AppData/Roaming/MCPforSketchUp/auth_token",
                 C.token_path(env: { "APPDATA" => "C:/Users/u/AppData/Roaming" }, platform: "x64-mingw-ucrt", home: "C:/Users/u")
    assert_equal "/Users/u/Library/Application Support/MCPforSketchUp/auth_token",
                 C.token_path(env: {}, platform: "arm64-darwin23", home: "/Users/u")
    assert_equal "/home/u/.config/MCPforSketchUp/auth_token",
                 C.token_path(env: {}, platform: "x86_64-linux", home: "/home/u")
  end
end

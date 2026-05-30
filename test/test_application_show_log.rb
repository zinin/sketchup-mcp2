require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"

class TestApplicationFileUri < Minitest::Test
  A = MCPforSketchUp::Core::Application

  def test_path_with_spaces_is_percent_encoded
    uri = A.send(:file_uri_for, "/tmp/hello world.log")
    assert_equal "file:///tmp/hello%20world.log", uri
  end

  def test_windows_drive_letter_path_gets_triple_slash
    # Exercise the REAL Application.file_uri_for. Stub File.expand_path to an
    # identity so POSIX expand_path doesn't mangle the Windows input (on Linux
    # File.expand_path("C:\\…") would prepend the cwd). file_uri_for's actual
    # responsibility — the backslash→slash + drive-letter + percent-escape
    # transform AFTER expand_path — is now verified directly. It was previously
    # stubbed out, so the test exercised a duplicate lambda, not the method under
    # test (codex 6th-review).
    File.stub(:expand_path, ->(*a) { a.first }) do
      uri = A.send(:file_uri_for, "C:\\Users\\foo bar\\mcp.log")
      assert_equal "file:///C:/Users/foo%20bar/mcp.log", uri
    end
  end

  def test_non_ascii_path_is_percent_encoded
    uri = A.send(:file_uri_for, "/tmp/журнал.log")
    # Non-ASCII bytes percent-encoded; exact bytes depend on encoding.
    refute_includes uri, "журнал", "non-ASCII characters must be escaped"
    assert_match(%r{\Afile:///tmp/(%[0-9A-F]{2})+\.log\z}i, uri)
  end
end

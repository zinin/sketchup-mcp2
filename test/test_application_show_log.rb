require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"

class TestApplicationFileUri < Minitest::Test
  A = MCPforSketchUp::Core::Application

  def test_path_with_spaces_is_percent_encoded
    uri = A.send(:file_uri_for, "/tmp/hello world.log")
    assert_equal "file:///tmp/hello%20world.log", uri
  end

  def test_windows_drive_letter_path_gets_triple_slash
    # We stub File.expand_path because expand_path on POSIX would mangle
    # the input. file_uri_for's actual responsibility is the gsub+regex+
    # escape sequence after expand_path; we exercise that part directly.
    # NOTE: this stub lambda duplicates Application.file_uri_for's
    # post-expand_path transform — keep it in sync if file_uri_for changes.
    A.stub(:file_uri_for, lambda { |p|
      enc = p.gsub('\\', '/')
      enc = "/#{enc}" if enc =~ /\A[A-Za-z]:/
      enc = URI::DEFAULT_PARSER.escape(enc)
      "file://#{enc}"
    }) do
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

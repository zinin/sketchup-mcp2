# test/test_version_triple.rb
# T-21: у релиза три Ruby-точки бампа версии — package.rb VERSION,
# extension.json "version" и Core::Compat::SERVER_VERSION. Loader пишет
# ext.version из package.rb, Extension Warehouse читает extension.json,
# handshake рапортует SERVER_VERSION — разъезд любой пары даёт .rbz с
# противоречивой самоидентификацией. Python-сторона закрыта зеркальным
# tests/test_compat.py::test_python_version_matches_installed_metadata.
require "minitest/autorun"
require "json"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"

class TestVersionTriple < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def server_version
    MCPforSketchUp::Core::Compat::SERVER_VERSION
  end

  def test_package_rb_version_matches_server_version
    src = File.read(File.join(ROOT, "mcp_for_sketchup", "package.rb"))
    m = src.match(/^VERSION = '([^']+)'/)
    refute_nil m, "package.rb: строка VERSION = '...' не найдена"
    assert_equal server_version, m[1],
      "package.rb VERSION (#{m[1]}) != Compat::SERVER_VERSION (#{server_version})"
  end

  def test_extension_json_version_matches_server_version
    meta = JSON.parse(File.read(File.join(ROOT, "mcp_for_sketchup", "extension.json")))
    assert_equal server_version, meta["version"],
      "extension.json version (#{meta['version']}) != Compat::SERVER_VERSION (#{server_version})"
  end
end

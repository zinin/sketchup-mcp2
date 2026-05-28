# test/test_extension_json.rb
# iter-2 QUESTION-3: pre-pack guard for the two extension.json fields
# whose values triggered the v0.1.0 warehouse rejection. Mirrors the
# post-build verify in Step 10.2 but runs at unit-test time, so a stray
# rename catches a CI failure rather than a re-rejection from Trimble.
require "minitest/autorun"
require "json"

class TestExtensionJson < Minitest::Test
  EXT_JSON = File.expand_path("../mcp_for_sketchup/extension.json", __dir__)

  def setup
    @meta = JSON.parse(File.read(EXT_JSON))
  end

  def test_product_id_matches_new_identity
    assert_equal "MCP_FOR_SKETCHUP", @meta["product_id"]
  end

  def test_name_matches_display
    assert_equal "MCP Server for SketchUp", @meta["name"]
  end
end

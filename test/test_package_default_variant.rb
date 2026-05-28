require "minitest/autorun"
require "zip"

class TestPackageDefaultVariant < Minitest::Test
  def test_default_variant_produces_warehouse_rbz_with_eval_disabled
    Dir.chdir(File.expand_path("../mcp_for_sketchup", __dir__)) do
      # Clean any prior build artifacts so the assertion checks THIS run.
      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
      ok = system({ "RUBYOPT" => nil }, "ruby", "package.rb",
                  out: File::NULL, err: File::NULL)
      assert ok, "package.rb without --variant exited non-zero"
      files = Dir.glob("mcp_for_sketchup_v*-warehouse.rbz")
      refute_empty files, "default variant should produce *-warehouse.rbz"

      # iter-2 SUGGESTION-1: assert the warehouse default actually baked
      # `EVAL_ENABLED_BY_DEFAULT = false` into the embedded build_profile.
      Zip::File.open(files.first) do |zf|
        entry = zf.find_entry("mcp_for_sketchup/core/build_profile.rb")
        refute_nil entry, "embedded build_profile.rb missing from #{files.first}"
        body = entry.get_input_stream.read
        assert_includes body, "EVAL_ENABLED_BY_DEFAULT = false",
          "warehouse build must bake EVAL_ENABLED_BY_DEFAULT = false; got: #{body.inspect}"
        assert_includes body, 'VARIANT                 = "warehouse"',
          "warehouse build must bake VARIANT = \"warehouse\"; got: #{body.inspect}"
      end

      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
    end
  end
end

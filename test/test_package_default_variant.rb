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
        refute_includes body, "docs/superpowers",
          "shipped build_profile.rb must not reference the removed docs/superpowers path; got: #{body.inspect}"
      end

      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
    end
  end

  def test_github_variant_produces_rbz_with_eval_enabled
    Dir.chdir(File.expand_path("../mcp_for_sketchup", __dir__)) do
      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
      ok = system({ "RUBYOPT" => nil }, "ruby", "package.rb", "--variant=github",
                  out: File::NULL, err: File::NULL)
      assert ok, "package.rb --variant=github exited non-zero"
      files = Dir.glob("mcp_for_sketchup_v*-github.rbz")
      refute_empty files, "github variant should produce *-github.rbz"

      # Mirror of the warehouse assertion: the github variant must bake the
      # OPPOSITE eval default so an eval-ON artifact is guarded end-to-end and
      # cannot silently regress to warehouse defaults (review F14).
      Zip::File.open(files.first) do |zf|
        entry = zf.find_entry("mcp_for_sketchup/core/build_profile.rb")
        refute_nil entry, "embedded build_profile.rb missing from #{files.first}"
        body = entry.get_input_stream.read
        assert_includes body, "EVAL_ENABLED_BY_DEFAULT = true",
          "github build must bake EVAL_ENABLED_BY_DEFAULT = true; got: #{body.inspect}"
        assert_includes body, 'VARIANT                 = "github"',
          "github build must bake VARIANT = \"github\"; got: #{body.inspect}"
        refute_includes body, "docs/superpowers",
          "shipped build_profile.rb must not reference the removed docs/superpowers path; got: #{body.inspect}"
      end

      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
    end
  end

  def test_invalid_variant_aborts_nonzero
    # package.rb must reject an unknown --variant with a non-zero exit and emit
    # no artifact, so a typo can't silently fall through to a default build
    # (review F15).
    Dir.chdir(File.expand_path("../mcp_for_sketchup", __dir__)) do
      ok = system({ "RUBYOPT" => nil }, "ruby", "package.rb", "--variant=bogus",
                  out: File::NULL, err: File::NULL)
      refute ok, "package.rb --variant=bogus must exit non-zero (abort)"
      assert_empty Dir.glob("mcp_for_sketchup_v*-bogus.rbz"),
        "no bogus-variant .rbz should be produced on abort"
    end
  end
end

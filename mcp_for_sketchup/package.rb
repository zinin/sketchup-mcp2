#!/usr/bin/env ruby
require 'zip'
require 'fileutils'

EXTENSION_NAME = 'mcp_for_sketchup'
VERSION = '0.4.0'

# There is exactly one build, so there are no options to parse — but silence is
# the wrong answer to an argument. `package.rb --variant=warehouse` used to
# produce an eval-DISABLED .rbz; ignoring it now would hand the caller an
# eval-ENABLED one and exit 0, which is the opposite of what they asked for.
# A stale release script or muscle memory must fail loudly, not silently invert.
unless ARGV.empty?
  abort "package.rb takes no arguments (got #{ARGV.inspect}); build variants " \
        "were removed in v0.3.1 — there is one .rbz and eval_ruby ships enabled"
end

OUTPUT_NAME = "#{EXTENSION_NAME}_v#{VERSION}.rbz"

temp_dir = "#{EXTENSION_NAME}_temp"
begin
  # 1. Prepare a temp staging directory.
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  FileUtils.mkdir_p(temp_dir)

  # .rbz must contain exactly one root .rb (the loader) + a same-named
  # directory (the extension subfolder); the Trimble signing service rejects
  # anything else at root with "Extra files found." The loader declares all
  # extension metadata via SketchupExtension.new, so nothing else is needed.
  # Guarded at test time by test/test_package_output.rb.
  FileUtils.cp_r(EXTENSION_NAME, temp_dir)
  FileUtils.cp("#{EXTENSION_NAME}.rb", temp_dir)

  # 2. Zip everything into the .rbz file. Wrap the zip in begin/rescue so a
  # crash MID-archive (disk full, I/O error) can't leave a partial/corrupt
  # .rbz: the outer `ensure` below cleans temp_dir but NOT OUTPUT_NAME, and a
  # leftover partial artifact could be shipped by a release glob
  # (gh release upload mcp_for_sketchup/*.rbz). rm_f only ever targets THIS
  # build's partial output — the rm below removes only the SAME-NAMED prior
  # artifact, so a differently-named leftover (e.g. a pre-0.3.1
  # *-warehouse.rbz) survives the build and is exactly what that release glob
  # would pick up. `rm -rf mcp_for_sketchup/*.rbz` in docs/release.md §3 is
  # what clears those; this line is not a substitute for it.
  FileUtils.rm(OUTPUT_NAME) if File.exist?(OUTPUT_NAME)
  begin
    Zip::File.open(OUTPUT_NAME, create: true) do |zipfile|
      Dir["#{temp_dir}/**/**"].each do |file|
        next if File.directory?(file)
        puts "Adding: #{file}"
        zipfile.add(file.sub("#{temp_dir}/", ''), file)
      end
    end
  rescue
    FileUtils.rm_f(OUTPUT_NAME)
    raise
  end
ensure
  # 3. Clean up — always runs, even on failure.
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
end

# 4. Post-build verification. What ships and carries the extension identity is
# the LOADER: a name or version regression there yields an .rbz that
# misidentifies itself in SketchUp's Extension Manager.
#
# A failed assertion here deletes OUTPUT_NAME before re-raising: the .rbz is
# complete but FAILED verification, so it must not survive for a release glob
# (e.g. `gh release upload mcp_for_sketchup/*.rbz`) to pick up.
begin
  Zip::File.open(OUTPUT_NAME) do |zf|
    loader = zf.find_entry("#{EXTENSION_NAME}.rb")
    raise "post-build: loader #{EXTENSION_NAME}.rb missing from #{OUTPUT_NAME}" unless loader
    loader_body = loader.get_input_stream.read
    unless loader_body.include?("'MCP Server for SketchUp'")
      raise "post-build: loader display name mismatch — expected 'MCP Server for SketchUp' in #{OUTPUT_NAME}"
    end
    unless loader_body =~ /ext\.version\s*=\s*'#{Regexp.escape(VERSION)}'/
      raise "post-build: loader version mismatch — expected #{VERSION} in #{OUTPUT_NAME}"
    end
    puts "post-build verified: loader name + version OK"
  end
rescue
  FileUtils.rm_f(OUTPUT_NAME)
  raise
end

puts "Created #{OUTPUT_NAME}"

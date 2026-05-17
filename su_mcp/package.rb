#!/usr/bin/env ruby

require 'zip'
require 'fileutils'

# Configuration
EXTENSION_NAME = 'su_mcp'
VERSION = '0.1.0'
OUTPUT_NAME = "#{EXTENSION_NAME}_v#{VERSION}.rbz"

# Create temp directory
temp_dir = "#{EXTENSION_NAME}_temp"
FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
FileUtils.mkdir_p(temp_dir)

# Copy files to temp directory.
# NB: an .rbz package must contain exactly one root .rb file (the loader)
# and a directory of the same name — anything else at root causes the
# Trimble Extension Signature service to reject the package with
# "Extra files found." `extension.json` lives INSIDE su_mcp/ (already
# carried by cp_r above) — do NOT copy it to root.
FileUtils.cp_r('su_mcp', temp_dir)
FileUtils.cp('su_mcp.rb', temp_dir)

# Create zip file
FileUtils.rm(OUTPUT_NAME) if File.exist?(OUTPUT_NAME)

Zip::File.open(OUTPUT_NAME, create: true) do |zipfile|
  Dir["#{temp_dir}/**/**"].each do |file|
    next if File.directory?(file)
    puts "Adding: #{file}"
    zipfile.add(file.sub("#{temp_dir}/", ''), file)
  end
end

# Clean up
FileUtils.rm_rf(temp_dir)

puts "Created #{OUTPUT_NAME}" 
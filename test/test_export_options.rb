# test/test_export_options.rb
# T-15: ключи exporter-хешей SketchUp строго именованы; неизвестный ключ
# МОЛЧА игнорируется. Официальный ключ OBJ — :doublesided_faces (без
# подчёркивания между double и sided); double_sided_faces тихо терял опцию.
require "minitest/autorun"

module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/export"

class TestExportOptions < Minitest::Test
  X = MCPforSketchUp::Handlers::Export

  class OptionsCapture
    attr_reader :last_path, :last_options
    def export(path, options)
      @last_path = path
      @last_options = options
      true
    end
  end

  def test_obj_uses_official_doublesided_faces_key
    model = OptionsCapture.new
    X.export_obj(model, "/tmp/x.obj")
    assert model.last_options.key?(:doublesided_faces),
      "официальный ключ OBJ-экспортёра — :doublesided_faces"
    refute model.last_options.key?(:double_sided_faces),
      "опечатанный ключ должен исчезнуть (SketchUp его молча игнорировал)"
    assert_equal true, model.last_options[:doublesided_faces]
    # M-03 (ревью): полный пин фактического obj-хеша — все ключи export_obj
    # под официальными именами; неизвестный ключ SketchUp игнорирует МОЛЧА.
    assert_equal({ triangulated_faces: true, doublesided_faces: true,
                   edges: false, texture_maps: true }, model.last_options)
  end

  def test_other_export_hashes_unchanged
    model = OptionsCapture.new
    X.export_dae(model, "/tmp/x.dae")
    assert_equal({ triangulated_faces: true }, model.last_options)
    X.export_stl(model, "/tmp/x.stl")
    assert_equal({ units: "model" }, model.last_options)
  end
end

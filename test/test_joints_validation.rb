# test/test_joints_validation.rb
# T-17: joints-offsets коэрсились .to_f молча ("abc" → 0.0). Валидация стоит ДО
# обращения к модели — пустых стабов Entities достаточно.
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end
module MCPforSketchUp
  module Helpers
    module Entities; end
  end
  module Handlers
    module Geometry; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointsValidation < Minitest::Test
  J = MCPforSketchUp::Handlers::Joints

  def test_string_offset_rejected_not_silently_zeroed
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      J.create_mortise_tenon("mortise_id" => 1, "tenon_id" => 2, "offset_x" => "abc")
    end
    assert_equal(-32602, err.code)
    assert_match(/offset_x/, err.message)
  end
end

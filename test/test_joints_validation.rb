# test/test_joints_validation.rb
# T-17: угол dovetail без верхней границы (tan(→90°) — мусорная геометрия);
# joints-offsets коэрсились .to_f молча ("abc" → 0.0). Валидация стоит ДО
# обращения к модели — пустых стабов Entities достаточно.
# M-07: num_tails ≤ 25 и num_fingers ≤ 50 — зеркало Field(le=...) в tools.py:
# прямой TCP-клиент обходит Python-схему.
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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointsValidation < Minitest::Test
  J = MCPforSketchUp::Handlers::Joints

  def test_dovetail_angle_above_60_rejected
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "angle" => 75.0)
    end
    assert_equal(-32602, err.code)
    assert_match(/angle/, err.message)
  end

  def test_dovetail_angle_at_60_passes_validation
    # 60° — граница включительно.
    assert_passes_validation do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "angle" => 60.0)
    end
  end

  def test_dovetail_num_tails_above_25_rejected
    assert_rejected("num_tails") do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "num_tails" => 26)
    end
  end

  def test_dovetail_num_tails_below_1_rejected
    assert_rejected("num_tails") do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "num_tails" => 0)
    end
  end

  def test_dovetail_num_tails_1_passes_validation
    assert_passes_validation do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "num_tails" => 1)
    end
  end

  def test_dovetail_num_tails_25_passes_validation
    assert_passes_validation do
      J.create_dovetail("tail_id" => 1, "pin_id" => 2, "num_tails" => 25)
    end
  end

  def test_finger_joint_num_fingers_above_50_rejected
    assert_rejected("num_fingers") do
      J.create_finger_joint("board1_id" => 1, "board2_id" => 2, "num_fingers" => 51)
    end
  end

  def test_finger_joint_num_fingers_below_1_rejected
    assert_rejected("num_fingers") do
      J.create_finger_joint("board1_id" => 1, "board2_id" => 2, "num_fingers" => 0)
    end
  end

  def test_finger_joint_num_fingers_1_passes_validation
    assert_passes_validation do
      J.create_finger_joint("board1_id" => 1, "board2_id" => 2, "num_fingers" => 1)
    end
  end

  def test_finger_joint_num_fingers_50_passes_validation
    assert_passes_validation do
      J.create_finger_joint("board1_id" => 1, "board2_id" => 2, "num_fingers" => 50)
    end
  end

  def test_string_offset_rejected_not_silently_zeroed
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      J.create_mortise_tenon("mortise_id" => 1, "tenon_id" => 2, "offset_x" => "abc")
    end
    assert_equal(-32602, err.code)
    assert_match(/offset_x/, err.message)
  end

  private

  def assert_rejected(field)
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { yield }
    assert_equal(-32602, err.code)
    assert_match(/#{field}/, err.message)
  end

  # Явный сигнал вместо NoMethodError (M-04): стаб active_model! кидает
  # маркер — тест не станет ложно-зелёным, если валидация переедет ниже по
  # методу. Method сохраняется: под run_all Entities реальный (def self. =
  # singleton-метод), remove_method без сохранения удалил бы его насовсем.
  # remove перед повторным define — чтобы `ruby -w` не ругался на redefine.
  def assert_passes_validation
    e = MCPforSketchUp::Helpers::Entities
    orig = e.respond_to?(:active_model!) ? e.method(:active_model!) : nil
    e.singleton_class.send(:remove_method, :active_model!) if orig
    e.define_singleton_method(:active_model!) { raise "validation passed" }
    err = assert_raises(RuntimeError) { yield }
    assert_equal "validation passed", err.message
  ensure
    e.singleton_class.send(:remove_method, :active_model!)
    e.define_singleton_method(:active_model!, orig) if orig
  end
end

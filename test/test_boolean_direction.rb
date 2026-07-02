# test/test_boolean_direction.rb
#
# Поведенческий пин реверса Group#subtract через Operations.boolean_operation:
# duck-typed группы записывают (receiver, argument) реального вызова #subtract.
# Source-guard'ы в test_operation_names.rb ловят правку literal-строки; этот
# файл ловит эквивалентный по тексту, но неверный по сути рефакторинг.
# Стабы — по конвенции сьюты: guarded-глобалы + setup/teardown-патч
# Helpers::Entities.active_model! (паттерн test_collect_components.rb).
#
# NB (порядок загрузки в run_all): этот файл («b») определяет Sketchup::Group
# ПЕРВЫМ guarded-пустышкой; test_collect_components.rb («c») затем
# ПЕРЕОТКРЫВАЕТ класс своим не-guarded стабом с методами — reopen легален,
# FakeSolid переопределяет всё, что трогают boolean_operation/describe_entity.
# Зависимость намеренно зафиксирована здесь; при странных падениях именно
# в run_all (но не поодиночке) — смотреть на состав стабов Group.
require "minitest/autorun"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestBooleanDirection < Minitest::Test
  OPS = MCPforSketchUp::Handlers::Operations
  EH  = MCPforSketchUp::Helpers::Entities

  FakePoint = Struct.new(:x, :y, :z)

  class FakeBounds
    attr_reader :min, :max
    def initialize(min, max)
      @min, @max = min, max
    end
    def center
      FakePoint.new((min.x + max.x) / 2.0, (min.y + max.y) / 2.0, (min.z + max.z) / 2.0)
    end
  end

  class FakeDefinition
    attr_reader :label, :bounds
    def initialize(label, bounds)
      @label, @bounds = label, bounds
    end
  end

  # add_instance = duplicate_group: возвращает «копию» с меткой copy_of_<src>.
  class FakeParentEntities
    def initialize(log)
      @log = log
    end
    def add_instance(definition, _transformation)
      FakeSolid.new(@log, label: "copy_of_#{definition.label}", bounds: definition.bounds)
    end
  end

  class FakeSolid < Sketchup::Group
    attr_reader :label, :bounds
    attr_accessor :parent
    def initialize(log, label:, bounds:)
      @log, @label, @bounds = log, label, bounds
      @valid = true
    end
    def definition
      FakeDefinition.new(@label, @bounds)
    end
    def transformation
      :identity
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def entityID
      object_id
    end
    def name
      @label
    end
    def union(other)
      @log << [:union, self, other]
      spawn_result
    end
    def subtract(other)
      @log << [:subtract, self, other]
      spawn_result
    end
    def intersect(other)
      @log << [:intersect, self, other]
      spawn_result
    end

    private

    def spawn_result
      FakeSolid.new(@log, label: "result", bounds: @bounds)
    end
  end

  class FakeModel
    def initialize(by_id)
      @by_id = by_id
    end
    def start_operation(_name, _disable_ui = true)
      true
    end
    def commit_operation
      true
    end
    def abort_operation
      true
    end
    def find_entity_by_id(int_id)
      @by_id[int_id]
    end
  end

  def setup
    @log = []
    bounds = FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(1, 2, 3))
    parent = Struct.new(:entities).new(FakeParentEntities.new(@log))
    @target = FakeSolid.new(@log, label: "target", bounds: bounds)
    @tool   = FakeSolid.new(@log, label: "tool",   bounds: bounds)
    @target.parent = parent
    @tool.parent   = parent
    model = FakeModel.new(101 => @target, 202 => @tool)
    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
  end

  def run_op(operation)
    OPS.boolean_operation(
      "operation" => operation, "target_id" => 101, "tool_id" => 202)
  end

  def test_difference_receiver_is_tool_copy_argument_is_target_copy
    run_op("difference")
    call = @log.find { |entry| entry[0] == :subtract }
    refute_nil call, "difference must go through Group#subtract"
    _, receiver, argument = call
    assert_equal "copy_of_tool", receiver.label,
      "receiver MUST be the TOOL copy: A.subtract(B) == B - A on SketchUp"
    assert_equal "copy_of_target", argument.label,
      "argument MUST be the TARGET copy"
  end

  def test_union_and_intersection_receiver_is_target_copy
    run_op("union")
    union_call = @log.find { |entry| entry[0] == :union }
    refute_nil union_call
    assert_equal "copy_of_target", union_call[1].label

    @log.clear
    run_op("intersection")
    intersect_call = @log.find { |entry| entry[0] == :intersect }
    refute_nil intersect_call
    assert_equal "copy_of_target", intersect_call[1].label
  end

  def test_originals_survive_when_delete_originals_false
    run_op("difference")
    assert @target.valid?, "original target must survive (delete_originals=false)"
    assert @tool.valid?,   "original tool must survive (delete_originals=false)"
  end
end

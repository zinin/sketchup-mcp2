# test/test_entities_identity.rb
# Solid-операции (subtract/union) возвращают НОВУЮ группу без имени, тега и
# собственного материала исходной. identity_of снимает их до операции,
# restore_identity! возвращает на результат.
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"

class TestEntitiesIdentity < Minitest::Test
  E = MCPforSketchUp::Helpers::Entities

  class FakeEntity
    attr_accessor :name, :layer, :material
    def initialize(name: "", layer: nil, material: nil)
      @name = name
      @layer = layer
      @material = material
    end
  end

  def test_identity_round_trip
    layer = Object.new
    mat = Object.new
    source = FakeEntity.new(name: "probe_rail", layer: layer, material: mat)

    identity = E.identity_of(source)
    target = FakeEntity.new
    result = E.restore_identity!(target, identity)

    assert_same target, result
    assert_equal "probe_rail", target.name
    assert_same layer, target.layer
    assert_same mat, target.material
  end

  def test_nil_material_leaves_the_target_alone
    layer = Object.new
    keep = Object.new
    target = FakeEntity.new(material: keep)

    E.restore_identity!(target, { name: "x", layer: layer, material: nil })

    assert_equal "x", target.name
    assert_same layer, target.layer
    assert_same keep, target.material
  end
end

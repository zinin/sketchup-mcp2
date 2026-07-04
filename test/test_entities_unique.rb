# test/test_entities_unique.rb
# T-16: entity_collection у ComponentInstance отдаёт definition.entities —
# ШАРИТСЯ между инстансами. Мутация через неё красит/режет ВСЕ инстансы
# («четыре стула краснеют разом»). Мутирующие пути обязаны идти через
# mutable_entity_collection (= make_unique + entity_collection).
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"

class TestEntitiesUnique < Minitest::Test
  E = MCPforSketchUp::Helpers::Entities

  FakeDefinition = Struct.new(:entities)

  class FakeInstance < Sketchup::ComponentInstance
    attr_reader :definition, :make_unique_calls
    def initialize(definition)
      @definition = definition
      @make_unique_calls = 0
    end
    def make_unique
      # Реальный SketchUp: инстанс отвязывается в СОБСТВЕННУЮ копию definition.
      @make_unique_calls += 1
      @definition = FakeDefinition.new(@definition.entities.dup)
      self
    end
  end

  class FakePlainGroup < Sketchup::Group
    attr_reader :entities
    def initialize
      @entities = [:g]
    end
    # namely: без make_unique — guard respond_to? обязан не падать
  end

  def test_mutable_collection_makes_instance_unique_first
    shared = FakeDefinition.new([:shared_face])
    inst_a = FakeInstance.new(shared)
    inst_b = FakeInstance.new(shared)

    coll = E.mutable_entity_collection(inst_a)

    assert_equal 1, inst_a.make_unique_calls, "make_unique обязан быть вызван до мутации"
    refute_same shared.entities, coll,
      "мутируемая коллекция должна принадлежать УНИКАЛЬНОЙ definition"
    assert_same shared, inst_b.definition, "второй инстанс остаётся на shared definition"
  end

  def test_mutable_collection_tolerates_entities_without_make_unique
    g = FakePlainGroup.new
    assert_equal [:g], E.mutable_entity_collection(g)
  end

  def test_readonly_entity_collection_does_not_make_unique
    shared = FakeDefinition.new([:shared_face])
    inst = FakeInstance.new(shared)
    E.entity_collection(inst)
    assert_equal 0, inst.make_unique_calls,
      "read-only обход НЕ должен плодить уникальные definitions"
  end
end

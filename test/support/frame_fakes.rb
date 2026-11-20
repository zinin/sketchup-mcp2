# test/support/frame_fakes.rb
# Parent chains for Helpers::Frames (block A): definitions, the groups and
# component instances placed from them, and face-like leaves — without
# SketchUp.
#
#   require_relative "support/frame_fakes"
#
#   leg  = FrameFakes::Definition.new("Leg")                     # a component
#   a    = FrameFakes.place(leg, id: 1, parent: model, matrix: m) # placed in the model
#   face = FrameFakes::Leaf.new(9, parent: leg, bounds: FrameFakes.bounds([0, 0, 0], [1, 1, 0]))
#
# Frames.placement walks entity.parent while it is a
# Sketchup::ComponentDefinition, so Definition subclasses that class and
# anything else (the model, any plain object) stops the walk. A placement
# subclasses Sketchup::Group or Sketchup::ComponentInstance, after its
# definition, because Entities.display_name and the handlers check is_a?.
#
# Under run_all other files define these Sketchup classes too, some
# unguarded and with an initialize of their own. The stubs here are guarded,
# and the subclasses define their own initialize and never call super, so
# either version works as their base.

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
  class ComponentDefinition; end unless defined?(ComponentDefinition)
end

module FrameFakes
  IDENTITY = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0].freeze

  # A transformation: to_a gives its 16 numbers, column-major like
  # Geom::Transformation#to_a.
  Transform = Struct.new(:values) do
    def to_a
      values
    end
  end

  Point  = Struct.new(:x, :y, :z)
  Bounds = Struct.new(:min, :max)

  # Bounds whose points answer x, y and z.
  def self.bounds(min, max)
    Bounds.new(Point.new(*min), Point.new(*max))
  end

  # A component or group definition. count_used_instances is `used` when a
  # test sets it (placements through the hierarchy), else the number of
  # instances.
  # entityID is unique, as a real definition's is: list_components' cycle
  # guard keys on it.
  class Definition < Sketchup::ComponentDefinition
    attr_accessor :name, :instances, :used, :bounds, :entities, :entityID

    def initialize(name, group: false, used: nil, bounds: nil)
      @entityID = object_id
      @name = name
      @group = group
      @used = used
      @bounds = bounds
      @instances = []
      @entities = []
    end

    def group?
      @group
    end

    def count_used_instances
      @used || @instances.length
    end
  end

  # What a group or component instance placed from a Definition answers.
  module Placed
    attr_accessor :entityID, :name, :parent, :transformation, :definition, :bounds, :layer

    def setup_placed(id, definition:, parent:, matrix:, name:)
      @entityID = id
      @definition = definition
      @parent = parent
      @transformation = Transform.new(matrix)
      @name = name
    end

    def valid?
      true
    end

    # A group's entities, as for a component instance, are its
    # definition's.
    def entities
      definition.entities
    end
  end

  class PlacedGroup < Sketchup::Group
    include Placed

    def initialize(*args, **kwargs)
      setup_placed(*args, **kwargs)
    end
  end

  class PlacedComponent < Sketchup::ComponentInstance
    include Placed

    def initialize(*args, **kwargs)
      setup_placed(*args, **kwargs)
    end
  end

  # Places `definition` in `parent` (a Definition or the model) and adds the
  # placement to definition.instances and, inside a Definition, to the
  # parent's entities. A group definition gives a PlacedGroup, a component
  # definition a PlacedComponent.
  def self.place(definition, id:, parent:, matrix: IDENTITY, name: "")
    klass = definition.group? ? PlacedGroup : PlacedComponent
    placed = klass.new(id, definition: definition, parent: parent, matrix: matrix, name: name)
    definition.instances << placed
    parent.entities << placed if parent.is_a?(Definition)
    placed
  end

  # A face or an edge: it lives in `parent` and has bounds.
  class Leaf
    attr_accessor :entityID, :parent, :bounds

    def initialize(id, parent:, bounds: nil)
      @entityID = id
      @parent = parent
      @bounds = bounds
    end

    def valid?
      true
    end

    def typename
      "Face"
    end
  end
end

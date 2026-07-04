# test/test_joints_frame_compensation.rb
#
# T-03: carve_tails / carve_pins / carve_board1_fingers обязаны компенсировать
# трансформацию доски (паттерн place_tenon), иначе геометрия джойнта улетает
# на |translation| от сдвинутой доски (живьём: промах ~1 м при сдвиге +800 мм).
#
# Фейки — translation-only алгебра: transform! складывает векторы, inverse
# отрицает. Ассерт вычисляет ЭФФЕКТИВНУЮ мировую X-координату каждой точки
# (board.T + instance.T + вложенные группы + сырая координата) и требует,
# чтобы геометрия осталась в мировом bbox доски ± глубина реза. Ассерт
# устойчив к обоим вариантам внутреннего устройства (старому add_group-пути
# и новому add_instance-пути) — красный/зелёный решает только СЕМАНТИКА.
#
# Границы теста (осознанные): проверяется ФРЕЙМ-КОМПЕНСАЦИЯ, не булева
# корректность результата (walk обходит и стёртые группы); алгебра
# translation-only — rotated-доски вне скоупа фикса. subtract_log —
# class-level и чистится в setup ЭТОГО класса; новые тест-классы должны
# заводить собственный лог, а не переиспользовать этот.
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
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointsFrameCompensation < Minitest::Test
  J  = MCPforSketchUp::Handlers::Joints
  EH = MCPforSketchUp::Helpers::Entities

  def self.subtract_log
    @subtract_log ||= []
  end

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

  # Translation-only стенд-ин Geom::Transformation.
  class FakeTranslation
    attr_reader :dx, :dy, :dz
    def initialize(dx = 0.0, dy = 0.0, dz = 0.0)
      @dx, @dy, @dz = dx, dy, dz
    end
    def inverse
      FakeTranslation.new(-dx, -dy, -dz)
    end
    def compose(other)
      FakeTranslation.new(dx + other.dx, dy + other.dy, dz + other.dz)
    end
  end

  class FakeFace
    def pushpull(_amount); end
  end

  # Записывает faces / вложенные группы / инстансы — walk-ассерт обходит всё.
  class FakeCollection
    attr_reader :faces, :groups, :instances
    def initialize
      @faces, @groups, @instances = [], [], []
    end
    def add_face(*pts)
      @faces << pts
      FakeFace.new
    end
    def add_group
      g = FakeGroup.new(parent_collection: self)
      @groups << g
      g
    end
    def add_instance(definition, transformation)
      @instances << { definition: definition, transformation: transformation }
      definition.owner
    end
  end

  class FakeGroup
    attr_reader :entities
    attr_reader :transformation
    def initialize(parent_collection: nil)
      @parent_collection = parent_collection
      @entities = FakeCollection.new
      @transformation = FakeTranslation.new
      @valid = true
    end
    def definition
      @definition ||= Struct.new(:owner).new(self)
    end
    def transform!(t)
      @transformation = @transformation.compose(t)
      self
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def subtract(target)
      TestJointsFrameCompensation.subtract_log << [self, target]
      result = FakeGroup.new(parent_collection: @parent_collection)
      @parent_collection.groups << result if @parent_collection
      erase!
      target.erase! if target.respond_to?(:erase!)
      result
    end
  end

  class FakeBoard < Sketchup::Group
    attr_reader :entities, :bounds, :transformation
    def initialize(bounds:, translation:)
      @entities = FakeCollection.new
      @bounds = bounds
      @transformation = translation
    end
  end

  class FakeModel
    attr_reader :active_entities
    def initialize
      @active_entities = FakeCollection.new
    end
  end

  # Доска, «созданная у origin (x 0..4) и сдвинутая на +30»: мировой bbox
  # x 30..34, transformation.dx = 30 — минимальный слепок живого репро
  # (create_component строит с identity-T, transform_component навешивает T).
  def make_board
    FakeBoard.new(
      bounds: FakeBounds.new(FakePoint.new(30.0, 0.0, 0.0), FakePoint.new(34.0, 4.0, 1.0)),
      translation: FakeTranslation.new(30.0, 0.0, 0.0),
    )
  end

  def setup
    self.class.subtract_log.clear
    @model = FakeModel.new
    model = @model
    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
  end

  # Эффективные мировые X всех точек, достижимых из коллекции доски.
  def world_xs(board)
    xs = []
    walk = lambda do |coll, offset|
      coll.faces.each { |pts| pts.each { |p| xs << p[0] + offset } }
      coll.groups.each do |g|
        walk.call(g.entities, offset + g.transformation.dx)
      end
      coll.instances.each do |inst|
        walk.call(inst[:definition].owner.entities, offset + inst[:transformation].dx)
      end
    end
    walk.call(board.entities, board.transformation.dx)
    xs
  end

  DEPTH = 0.5

  def assert_geometry_on_board(board, label)
    xs = world_xs(board)
    refute_empty xs, "#{label} must add geometry into the board"
    lo = board.bounds.min.x - DEPTH - 1e-6
    hi = board.bounds.max.x + DEPTH + 1e-6
    assert xs.min >= lo && xs.max <= hi,
      "#{label}: geometry escaped the board's world bbox (got x " \
      "#{xs.min.round(3)}..#{xs.max.round(3)}, allowed #{lo.round(3)}..#{hi.round(3)}) — " \
      "parent-frame coords drawn into board-local entities (T-03)"
  end

  def test_carve_tails_lands_on_translated_board
    board = make_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_tails")
  end

  def test_carve_pins_lands_on_translated_board_and_counts_cuts
    board = make_board
    J.reset_joint_stats!
    J.carve_pins(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_pins")
    assert_equal 3, J.joint_cut_stats["attempted"], "3 tail-slot cuts expected"
    refute_empty self.class.subtract_log, "pins must be carved via Group#subtract"
  end

  def test_carve_board1_fingers_lands_on_translated_board_and_counts_cuts
    board = make_board
    J.reset_joint_stats!
    J.carve_board1_fingers(board, 2.0, 2.0, DEPTH, 5, 0, 0, 0)
    assert_geometry_on_board(board, "carve_board1_fingers")
    assert_equal 2, J.joint_cut_stats["attempted"], "num_fingers/2 cuts expected"
  end

  def test_scratch_prototypes_are_erased_from_model_root
    board = make_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    leftovers = @model.active_entities.groups.select(&:valid?)
    assert_empty leftovers,
      "world-frame scratch group must be erased after instancing (place_tenon pattern)"
  end

  # Source-пин: carve-хелперы обязаны строить через add_parent_frame_prototype —
  # «оптимизация» в обход хелпера вернула бы двойное смещение T-03.
  def test_carve_helpers_route_through_parent_frame_prototype
    src = File.read(File.expand_path(
      "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb", __dir__))
    %w[carve_tails carve_pins carve_board1_fingers].each do |name|
      body = src[/def self\.#{name}\b(?:(?!\n      def self\.).)*/m]
      refute_nil body, "#{name} not found in joints.rb"
      assert_match(/add_parent_frame_prototype\(board\)/, body,
        "#{name} must build via add_parent_frame_prototype(board)")
    end
  end

  # Source-пин ОСОЗНАННОЙ асимметрии: carve_board2_slots НЕ идёт через
  # add_parent_frame_prototype — его cutter обязан быть SIBLING'ом доски
  # (current.parent.entities), иначе Group#subtract не сработает (паттерн
  # place_mortise). Будущая «гармонизация» под общий prototype-хелпер —
  # регрессия, а не рефакторинг (финальное ревью ветки: deepseek + minimax).
  # Намеренный literal-пин: обновлять осознанно, не «чинить» под форматтер.
  def test_carve_board2_slots_keeps_sibling_cutter_pattern
    src = File.read(File.expand_path(
      "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb", __dir__))
    body = src[/def self\.carve_board2_slots\b(?:(?!\n      def self\.).)*/m]
    refute_nil body, "carve_board2_slots not found in joints.rb"
    assert_match(/current\.parent\.entities\.add_group/, body,
      "carve_board2_slots must build its cutter as a SIBLING of the board " \
      "(current.parent.entities) — Group#subtract requires sibling groups")
    refute_match(/add_parent_frame_prototype/, body,
      "carve_board2_slots must NOT route through add_parent_frame_prototype")
  end
end

# MR-3 (финальное ревью батча 1): translation-only алгебра не доказывает
# компенсацию T⁻¹ для ПОВЁРНУТЫХ досок. Аффинная подгруппа: повороты вокруг
# Z на 0/90/180/270 (точная целочисленная математика — без float-фазза) +
# сдвиг. Компенсация add_parent_frame_prototype (T_inst = T_board⁻¹) обязана
# сокращать И поворот: world = T_board ∘ T_board⁻¹ ∘ p = p.
# C-09: тест доказывает АЛГОРИТМ компенсации (логику T⁻¹); float-поведение
# реального Geom::Transformation при композиции матриц покрывает только
# живой smoke на SketchUp.
class TestJointsFrameCompensationRotated < Minitest::Test
  J  = MCPforSketchUp::Handlers::Joints
  EH = MCPforSketchUp::Helpers::Entities

  def self.subtract_log
    @subtract_log ||= []
  end

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

  # Поворот вокруг Z на deg ∈ {0, 90, 180, 270} + сдвиг: apply = R(p) + d.
  class FakeAffineZ
    attr_reader :deg, :dx, :dy, :dz
    def initialize(deg = 0, dx = 0.0, dy = 0.0, dz = 0.0)
      @deg = deg % 360
      @dx, @dy, @dz = dx, dy, dz
    end

    def rot(x, y)
      case deg
      when 0   then [x, y]
      when 90  then [-y, x]
      when 180 then [-x, -y]
      else          [y, -x]
      end
    end

    def apply(p)
      x, y = rot(p[0], p[1])
      [x + dx, y + dy, p[2] + dz]
    end

    # self ∘ other: сначала other, потом self.
    # (A∘B).apply(p) = R_A(R_B(p) + d_B) + d_A = R_{A+B}(p) + (R_A(d_B) + d_A)
    def compose(other)
      ox, oy = rot(other.dx, other.dy)
      FakeAffineZ.new(deg + other.deg, ox + dx, oy + dy, dz + other.dz)
    end

    # T⁻¹: R⁻¹(p − d) = R_{−deg}(p) − R_{−deg}(d)
    def inverse
      inv = FakeAffineZ.new((360 - deg) % 360)
      ix, iy = inv.rot(-dx, -dy)
      FakeAffineZ.new((360 - deg) % 360, ix, iy, -dz)
    end
  end

  class FakeFace
    def pushpull(_amount); end
  end

  class FakeCollection
    attr_reader :faces, :groups, :instances
    def initialize
      @faces, @groups, @instances = [], [], []
    end
    def add_face(*pts)
      @faces << pts
      FakeFace.new
    end
    def add_group
      g = FakeGroup.new(parent_collection: self)
      @groups << g
      g
    end
    def add_instance(definition, transformation)
      @instances << { definition: definition, transformation: transformation }
      definition.owner
    end
  end

  class FakeGroup
    attr_reader :entities, :transformation
    def initialize(parent_collection: nil)
      @parent_collection = parent_collection
      @entities = FakeCollection.new
      @transformation = FakeAffineZ.new
      @valid = true
    end
    def definition
      @definition ||= Struct.new(:owner).new(self)
    end
    def transform!(t)
      # SketchUp transform!: результат = t ∘ старая (t применяется ПОСЛЕ).
      @transformation = t.compose(@transformation)
      self
    end
    def valid?
      @valid
    end
    def erase!
      @valid = false
    end
    def subtract(target)
      TestJointsFrameCompensationRotated.subtract_log << [self, target]
      result = FakeGroup.new(parent_collection: @parent_collection)
      @parent_collection.groups << result if @parent_collection
      erase!
      target.erase! if target.respond_to?(:erase!)
      result
    end
  end

  class FakeBoard < Sketchup::Group
    attr_reader :entities, :bounds, :transformation
    def initialize(bounds:, transformation:)
      @entities = FakeCollection.new
      @bounds = bounds
      @transformation = transformation
    end
  end

  class FakeModel
    attr_reader :active_entities
    def initialize
      @active_entities = FakeCollection.new
    end
  end

  # Доска «создана у origin (x 0..4, y 0..4), повёрнута на 90° и сдвинута
  # на dx=30»: R90 даёт x' = −y + 30 ∈ [26..30], y' = x ∈ [0..4] — мировой
  # bbox (родительский фрейм) x 26..30, y 0..4 (C-14: легенда согласована
  # с трансформацией алгебраически).
  def make_rotated_board
    FakeBoard.new(
      bounds: FakeBounds.new(FakePoint.new(26.0, 0.0, 0.0), FakePoint.new(30.0, 4.0, 1.0)),
      transformation: FakeAffineZ.new(90, 30.0, 0.0, 0.0),
    )
  end

  def setup
    self.class.subtract_log.clear
    @model = FakeModel.new
    model = @model
    @saved_active_model = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
  end

  def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
  end

  # Мировые (x, y) всех точек, достижимых из коллекции доски: аккумулируем
  # композицию трансформаций сверху вниз.
  def world_points(board)
    pts = []
    walk = lambda do |coll, acc|
      coll.faces.each { |face| face.each { |p| pts << acc.apply(p) } }
      coll.groups.each { |g| walk.call(g.entities, acc.compose(g.transformation)) }
      coll.instances.each do |inst|
        walk.call(inst[:definition].owner.entities, acc.compose(inst[:transformation]))
      end
    end
    walk.call(board.entities, board.transformation)
    pts
  end

  DEPTH = 0.5

  def assert_geometry_on_board(board, label)
    pts = world_points(board)
    refute_empty pts, "#{label} must add geometry into the board"
    lo_x = board.bounds.min.x - DEPTH - 1e-6
    hi_x = board.bounds.max.x + DEPTH + 1e-6
    lo_y = board.bounds.min.y - DEPTH - 1e-6
    hi_y = board.bounds.max.y + DEPTH + 1e-6
    xs = pts.map { |p| p[0] }
    ys = pts.map { |p| p[1] }
    assert xs.min >= lo_x && xs.max <= hi_x && ys.min >= lo_y && ys.max <= hi_y,
      "#{label}: геометрия ушла с ПОВЁРНУТОЙ доски (x #{xs.min.round(3)}..#{xs.max.round(3)}, " \
      "y #{ys.min.round(3)}..#{ys.max.round(3)}; допустимо x #{lo_x}..#{hi_x}, y #{lo_y}..#{hi_y}) — " \
      "компенсация T_board⁻¹ не сокращает поворот (MR-3)"
  end

  def test_carve_tails_lands_on_rotated_board
    board = make_rotated_board
    J.carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)
    assert_geometry_on_board(board, "carve_tails")
  end

  def test_carve_board1_fingers_lands_on_rotated_board
    board = make_rotated_board
    J.reset_joint_stats!
    J.carve_board1_fingers(board, 2.0, 2.0, DEPTH, 5, 0, 0, 0)
    assert_geometry_on_board(board, "carve_board1_fingers")
  end
end

# test/test_operation_names.rb
# Source-level guards against regressing the Undo-menu labels back to
# snake_case identifiers. Title Case is required here because these
# strings are user-visible in SketchUp's Edit → Undo / Redo menu. Every
# handler passes its label to Helpers::Operation.run (`O.run(model, "…")`),
# the one place that calls start_operation. These tests parse the handler
# files directly to avoid stubbing the entire Sketchup::Model API.
require "minitest/autorun"

class TestOperationNames < Minitest::Test
  HANDLERS = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/handlers", __dir__)

  def source(rel_dir, file)
    File.read(File.join(rel_dir, file), encoding: "UTF-8")
  end

  def assert_op_label(src, regex, description)
    m = src.match(regex)
    refute_nil m, "#{description}: expected label matching #{regex.inspect}"
  end

  def test_geometry_labels_are_title_case
    src = source(HANDLERS, "geometry.rb")
    assert_op_label src, /O\.run\(model, "Create Component \(#\{type\.capitalize\}\)"/,
      "create_component"
    assert_op_label src, /O\.run\(model, "Delete Component"/, "delete_component"
    assert_op_label src, /O\.run\(model, "Transform Component"/, "transform_component"
  end

  def test_operations_labels_are_title_case
    src = source(HANDLERS, "operations.rb")
    assert_op_label src, /O\.run\(model, "Boolean #\{operation\.capitalize\}"/, "boolean_operation"
    # run_edge_op gets op_name from caller. We assert callers pass Title Case strings.
    assert_op_label src, /run_edge_op\(entity_id, edge_indices, "Chamfer Edges"/, "chamfer_edges"
    assert_op_label src, /run_edge_op\(entity_id, edge_indices, "Fillet Edges"/, "fillet_edges"
  end

  # Source-level guard (kimi review): run_edge_op must type-check edge_indices
  # to a -32602 invalid-params BEFORE the operation starts (O.run), so a non-Array from a
  # direct/malformed TCP client (bypassing the FastMCP schema) can't reach
  # filter_edges -> include? and surface as a generic -32603. A behavioural
  # exercise needs the full model API (avoided in this file by design), so the
  # guard's presence + shape is asserted in source.
  def test_run_edge_op_type_guards_edge_indices_to_invalid_params
    src = source(HANDLERS, "operations.rb")
    guard = src[/def self\.run_edge_op.*?O\.run\(/m]
    refute_nil guard, "run_edge_op def → O.run region not found"
    assert_match(/edge_indices && !edge_indices\.is_a\?\(Array\)/, guard,
      "run_edge_op must type-guard edge_indices as an Array before the operation starts")
    assert_match(/StructuredError\.new\(-32602/, guard,
      "non-Array edge_indices must raise -32602 invalid-params, not a generic -32603")
  end

  def test_joints_labels_are_title_case
    src = source(HANDLERS, "joints.rb")
    assert_op_label src, /O\.run\(model, "Mortise and Tenon"/, "mortise_tenon"
  end

  def test_materials_label_is_title_case
    src = source(HANDLERS, "materials.rb")
    assert_op_label src, /O\.run\(model, "Set Material \(#\{name\.capitalize\}\)"/, "set_material"
  end

  def test_model_create_layer_label_is_title_case
    src = source(HANDLERS, "model.rb")
    assert_op_label src, /O\.run\(m, "Create Layer \(#\{name\}\)"/, "create_layer"
  end

  def test_handlers_dir_is_not_empty
    # Iter-1 SUGGESTION-6: catch a stale HANDLERS path before silently
    # passing every other assertion with a 0-file glob.
    files = Dir[File.join(HANDLERS, "*.rb")]
    refute_empty files, "handlers dir scan returned 0 files — check HANDLERS path: #{HANDLERS}"
  end

  def test_no_snake_case_op_labels_remain
    # Catch-all regression guard. The pattern matches an O.run call whose
    # label literal begins with a lowercase letter (i.e. snake_case)
    # OR contains a colon-separator like "boolean_operation:union". Both are
    # forms this file exists to keep out of the Undo menu.
    Dir[File.join(HANDLERS, "*.rb")].each do |path|
      File.read(path, encoding: "UTF-8").scan(/\bO\.run\(\w+, "([^"]+)"/).each do |(literal_arg)|
        # Allow interpolation marker `#{...}` anywhere; check the static
        # prefix only. A capitalised first letter passes.
        first_visible = literal_arg.sub(/\A#\{[^}]*\}/, '')[0]
        next if first_visible.nil?
        refute_match(/[a-z_]/, first_visible.to_s,
          "snake_case label leaked into O.run in #{File.basename(path)}: #{literal_arg.inspect}")
      end
    end
  end

  # M-16: Helpers::Operation.run is the only place that starts, commits or
  # aborts an operation. A handler that called them itself would bypass the
  # wrapper's abort-on-any-exception and response-before-commit contract.
  # Comment lines do not count.
  def test_handlers_open_operations_only_through_the_wrapper
    Dir[File.join(HANDLERS, "*.rb")].each do |path|
      code = File.read(path, encoding: "UTF-8").lines.grep_v(/\A\s*#/).join
      refute_match(/\b(?:start|commit|abort)_operation\b|\bsafe_abort\b/, code,
        "#{File.basename(path)} must open, commit and abort operations only through O.run")
    end
  end

  # --- T-10: реверс Group#subtract — самый опасный инвариант проекта ---
  # SketchUp: A.subtract(B) == B − A (проверено эмпирически на SU2026;
  # официальные доки противоречат сами себе — описание метода говорит
  # this − arg, описание параметра обратное). Флип на «очевидный» порядок
  # сегодня прошёл бы всю сьюту — эти guard'ы делают его красным.
  # NB: guard'ы — НАМЕРЕННЫЕ literal-пины исходника; переформатирование или
  # переименование локальных переменных красит их. Это ожидаемо: обновляй
  # пин осознанно вместе с семантической проверкой, не «чини» под форматтер.

  def test_boolean_difference_receiver_is_tool_copy
    src = source(HANDLERS, "operations.rb")
    assert_match(/when "difference"\s+then tool_copy\.subtract\(target_copy\)/, src,
      "difference MUST stay tool_copy.subtract(target_copy): SketchUp's " \
      "Group#subtract is reversed (A.subtract(B) == B - A). Do NOT 'fix' " \
      "the order to match the official docs — they are self-contradictory.")
  end

  def test_edge_ops_subtract_receiver_is_cutter
    src = source(HANDLERS, "operations.rb")
    assert_match(/result = cutter\.subtract\(entity\)/, src,
      "run_edge_op must call cutter.subtract(entity) to get entity - cutter")
  end

  def test_joints_subtract_call_sites_keep_cutter_first
    src = source(HANDLERS, "joints.rb")
    [
      /result = cutter\.subtract\(board\)/,
    ].each do |pattern|
      assert_match(pattern, src,
        "joints must keep the CUTTER as the receiver of the reversed Group#subtract " \
        "(cutter.subtract(board) == board - cutter): missing #{pattern.inspect}")
    end
  end
end

# test/test_operation_names.rb
# Source-level guards against regressing the Undo-menu labels back to
# snake_case identifiers. The reviewer's warehouse rejection (note 1)
# requires Title Case strings here because they are user-visible in
# SketchUp's Edit → Undo / Redo menu. These tests parse the handler
# files directly to avoid stubbing the entire Sketchup::Model API.
require "minitest/autorun"

class TestOperationNames < Minitest::Test
  HANDLERS = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/handlers", __dir__)
  CORE     = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/core", __dir__)

  def source(rel_dir, file)
    File.read(File.join(rel_dir, file))
  end

  def assert_op_label(src, regex, description)
    m = src.match(regex)
    refute_nil m, "#{description}: expected label matching #{regex.inspect}"
  end

  def test_geometry_labels_are_title_case
    src = source(HANDLERS, "geometry.rb")
    assert_op_label src, /start_operation\("Create Component \(#\{type\.capitalize\}\)"/,
      "create_component"
    assert_op_label src, /start_operation\("Delete Component"/, "delete_component"
    assert_op_label src, /start_operation\("Transform Component"/, "transform_component"
  end

  def test_operations_labels_are_title_case
    src = source(HANDLERS, "operations.rb")
    assert_op_label src, /start_operation\("Boolean #\{operation\.capitalize\}"/, "boolean_operation"
    # run_edge_op gets op_name from caller. We assert callers pass Title Case strings.
    assert_op_label src, /run_edge_op\(entity_id, edge_indices, "Chamfer Edges"/, "chamfer_edges"
    assert_op_label src, /run_edge_op\(entity_id, edge_indices, "Fillet Edges"/, "fillet_edges"
  end

  # Source-level guard (kimi review): run_edge_op must type-check edge_indices
  # to a -32602 invalid-params BEFORE start_operation, so a non-Array from a
  # direct/malformed TCP client (bypassing the FastMCP schema) can't reach
  # filter_edges -> include? and surface as a generic -32603. A behavioural
  # exercise needs the full model API (avoided in this file by design), so the
  # guard's presence + shape is asserted in source.
  def test_run_edge_op_type_guards_edge_indices_to_invalid_params
    src = source(HANDLERS, "operations.rb")
    guard = src[/def self\.run_edge_op.*?model\.start_operation/m]
    refute_nil guard, "run_edge_op def → start_operation region not found"
    assert_match(/edge_indices && !edge_indices\.is_a\?\(Array\)/, guard,
      "run_edge_op must type-guard edge_indices as an Array before start_operation")
    assert_match(/StructuredError\.new\(-32602/, guard,
      "non-Array edge_indices must raise -32602 invalid-params, not a generic -32603")
  end

  def test_joints_labels_are_title_case
    src = source(HANDLERS, "joints.rb")
    assert_op_label src, /start_operation\("Mortise and Tenon"/, "mortise_tenon"
    assert_op_label src, /start_operation\("Dovetail Joint"/, "dovetail"
    assert_op_label src, /start_operation\("Finger Joint"/, "finger_joint"
  end

  def test_materials_label_is_title_case
    src = source(HANDLERS, "materials.rb")
    assert_op_label src, /start_operation\("Set Material \(#\{name\.capitalize\}\)"/, "set_material"
  end

  def test_model_create_layer_label_is_title_case
    src = source(HANDLERS, "model.rb")
    assert_op_label src, /start_operation\("Create Layer \(#\{name\}\)"/, "create_layer"
  end

  def test_handlers_dir_is_not_empty
    # Iter-1 SUGGESTION-6: catch a stale HANDLERS path before silently
    # passing every other assertion with a 0-file glob.
    files = Dir[File.join(HANDLERS, "*.rb")]
    refute_empty files, "handlers dir scan returned 0 files — check HANDLERS path: #{HANDLERS}"
  end

  def test_no_snake_case_op_labels_remain
    # Catch-all regression guard. The pattern matches a start_operation call
    # whose first arg literal begins with a lowercase letter (i.e. snake_case)
    # OR contains a colon-separator like "boolean_operation:union". Both
    # were the form reviewer rejected.
    Dir[File.join(HANDLERS, "*.rb")].each do |path|
      File.read(path).scan(/start_operation\("([^"]+)"/).each do |(literal_arg)|
        # Allow interpolation marker `#{...}` anywhere; check the static
        # prefix only. A capitalised first letter passes.
        first_visible = literal_arg.sub(/\A#\{[^}]*\}/, '')[0]
        next if first_visible.nil?
        refute_match(/[a-z_]/, first_visible.to_s,
          "snake_case label leaked into start_operation in #{File.basename(path)}: #{literal_arg.inspect}")
      end
    end
  end
end

# SketchUp Ruby Cookbook (eval_ruby)

Reference snippets for driving the SketchUp Ruby API directly via the
`eval_ruby` MCP tool. Use this when the high-level handlers
(`create_component`, `transform_component`, `boolean_operation`, joints…)
don't cover what you need — full models with walls, roofs, framing,
joist arrays, follow_me extrusions, transforms, world-space queries.

## Units: always convert mm ↔ inches

SketchUp stores all coordinates internally in **inches**, regardless of
model settings. Always convert at the boundary:

```ruby
MM = 25.4
# mm → inches (for input to API)
val_in = 100.0 / MM   # 100 mm → inches

# inches → mm (for reading from API)
val_mm = bounds.max.x * MM
```

## Inspect the open model

```ruby
model = Sketchup.active_model
MM = 25.4

# File path and title
model.path    # => "C:/path/to/file.skp"
model.title   # => "mymodel"

# Overall bounding box in mm
bb = model.bounds
size = "#{((bb.max.x-bb.min.x)*MM).round(1)} x #{((bb.max.y-bb.min.y)*MM).round(1)} x #{((bb.max.z-bb.min.z)*MM).round(1)} mm"

# List layers/tags with group counts
model.entities.grep(Sketchup::Group)
  .group_by{|g| g.layer.name}
  .map{|name, gs| "#{name}: #{gs.count}"}

# List all layer names
model.layers.map(&:name)
```

## Find and select entities

```ruby
# All groups on a specific layer
grps = model.entities.grep(Sketchup::Group).select{|g| g.layer.name == "Стены"}

# Find by entity ID (model level, not entities level!)
grp = model.find_entity_by_id(12345)   # correct
# model.entities.find_entity_by_id(id)  # WRONG — method doesn't exist

# Select in UI
model.selection.clear
grps.each{|g| model.selection.add(g)}

# Bounding box of a group in mm
bb = grp.bounds
w = (bb.max.x - bb.min.x) * MM
d = (bb.max.y - bb.min.y) * MM
h = (bb.max.z - bb.min.z) * MM

# Combined bbox of multiple groups (BoundingBox has no + operator)
min_x = grps.map{|g| g.bounds.min.x}.min
max_x = grps.map{|g| g.bounds.max.x}.max
# same for y, z
```

## Create geometry — reliable make_box helper

**Critical:** `face.pushpull` direction follows the face normal, which SketchUp determines
automatically and is NOT always +Z. Always check `face.normal.z` before pushing.

```ruby
MM = 25.4

# Safe box: always extrudes upward (+Z) regardless of face normal direction
def make_box(parent_ents, x_mm, y_mm, z_mm, w_mm, d_mm, h_mm)
  mm = 25.4
  grp = parent_ents.add_group
  face = grp.entities.add_face(
    [x_mm/mm,            y_mm/mm,            z_mm/mm],
    [(x_mm + w_mm)/mm,   y_mm/mm,            z_mm/mm],
    [(x_mm + w_mm)/mm,   (y_mm + d_mm)/mm,   z_mm/mm],
    [x_mm/mm,            (y_mm + d_mm)/mm,   z_mm/mm]
  )
  sign = face.normal.z >= 0 ? 1 : -1
  face.pushpull(sign * h_mm / mm)
  grp
end

model = Sketchup.active_model
model.start_operation("Build", true)

grp = make_box(model.entities, 0, 0, 0, 150, 150, 75)   # bottom plate
grp.name  = "bottom_plate"
grp.layer = model.layers["Обвязка"]

model.commit_operation
# grp.entityID is the stable integer ID for future lookups
```

## Stack elements precisely

Use `bounds.max.z` of the lower object as the `z_mm` start of the next one:

```ruby
MM = 25.4
# bounds of a group are in parent's local space (= world space if group is top-level)
# For nested sub-groups, bounds are in the parent group's local space
top_z_mm = (some_group.bounds.max.z * MM).round(3)
next_grp = make_box(model.entities, x, y, top_z_mm, w, d, h)
```

## Framed wall (studs + plates)

```ruby
MM = 25.4
model.start_operation("Wall", true)

wall_l = 3000.0; wall_d = 150.0; stud_h = 2850.0; plate_h = 75.0; stud_w = 50.0

wall = model.entities.add_group
wall.name = "wall_section"
wall.layer = model.layers["Стены"]

make_box(wall.entities, 0, 0, 0,              wall_l, wall_d, plate_h).name = "bottom_plate"
make_box(wall.entities, 0, 0, plate_h+stud_h, wall_l, wall_d, plate_h).name = "top_plate"

x = 0.0; i = 0
while x <= wall_l - stud_w
  make_box(wall.entities, x, 0, plate_h, stud_w, wall_d, stud_h).name = "stud_#{i}"
  x += 600.0; i += 1
end

model.commit_operation
```

## Wall with opening (door / window)

SketchUp automatically creates a hole when two coplanar faces share a loop.
Create the outer face and the opening face in the same group's entities, then pushpull the outer face.

```ruby
MM = 25.4
model.start_operation("Wall with opening", true)

wall_l = 3000.0; wall_t = 150.0; wall_h = 3000.0
op_x = 1000.0; op_w = 1000.0; op_z = 800.0; op_h = 1200.0

grp = model.entities.add_group
grp.layer = model.layers["Стены"]
e = grp.entities

# Outer wall face
outer = e.add_face(
  [0,          0, 0          ].map{|v| v/MM},
  [wall_l/MM,  0, 0          ],
  [wall_l/MM,  0, wall_h/MM  ],
  [0,          0, wall_h/MM  ]
)
# Opening face (coplanar, same plane) — SketchUp cuts the hole automatically
e.add_face(
  [op_x/MM,         0, op_z/MM        ],
  [(op_x+op_w)/MM,  0, op_z/MM        ],
  [(op_x+op_w)/MM,  0, (op_z+op_h)/MM ],
  [op_x/MM,         0, (op_z+op_h)/MM ]
)
# The outer face now has loops=2 (hole punched); pushpull extrudes the frame
sign = outer.normal.y.abs > 0.5 ? (outer.normal.y > 0 ? 1 : -1) : 1
outer.pushpull(sign * wall_t / MM)

model.commit_operation
# Verify: outer face should have face.loops.count == 2
```

## Gable roof (двускатная)

```ruby
MM = 25.4
bld_w = 4000.0; bld_l = 6000.0; ridge_h = 1500.0; z0 = 3000.0

model.start_operation("Gable roof", true)
grp = model.entities.add_group
grp.layer = model.layers["Кровля"]
e = grp.entities

# Left slope
e.add_face(
  [0,           0,         z0/MM         ],
  [0,           bld_l/MM,  z0/MM         ],
  [(bld_w/2)/MM, bld_l/MM, (z0+ridge_h)/MM],
  [(bld_w/2)/MM, 0,        (z0+ridge_h)/MM]
)
# Right slope
e.add_face(
  [bld_w/MM,     0,        z0/MM         ],
  [(bld_w/2)/MM, 0,        (z0+ridge_h)/MM],
  [(bld_w/2)/MM, bld_l/MM, (z0+ridge_h)/MM],
  [bld_w/MM,     bld_l/MM, z0/MM         ]
)
# Gable ends (triangles)
e.add_face([0,            0,        z0/MM], [bld_w/MM, 0,       z0/MM], [(bld_w/2)/MM, 0,       (z0+ridge_h)/MM])
e.add_face([0,            bld_l/MM, z0/MM], [(bld_w/2)/MM, bld_l/MM, (z0+ridge_h)/MM], [bld_w/MM, bld_l/MM, z0/MM])

model.commit_operation
```

## Hip roof (вальмовая)

```ruby
MM = 25.4
bld_w = 6000.0; bld_l = 4000.0; ridge_h = 1200.0; z0 = 3000.0

# Ridge runs along the long axis, inset by bld_l/2 from each short end
rs_x = bld_l / 2.0; re_x = bld_w - bld_l / 2.0
ry   = bld_l / 2.0; rz   = z0 + ridge_h

model.start_operation("Hip roof", true)
grp = model.entities.add_group
grp.layer = model.layers["Кровля"]
e = grp.entities

e.add_face([0,       0,        z0/MM], [bld_w/MM,  0,       z0/MM], [re_x/MM, ry/MM, rz/MM], [rs_x/MM, ry/MM, rz/MM])  # front
e.add_face([0,       bld_l/MM, z0/MM], [rs_x/MM, ry/MM, rz/MM], [re_x/MM, ry/MM, rz/MM], [bld_w/MM, bld_l/MM, z0/MM])  # back
e.add_face([0,       0,        z0/MM], [rs_x/MM, ry/MM, rz/MM], [0, bld_l/MM, z0/MM])   # left (triangle)
e.add_face([bld_w/MM,0,        z0/MM], [bld_w/MM, bld_l/MM, z0/MM], [re_x/MM, ry/MM, rz/MM])  # right (triangle)

model.commit_operation
```

## Rafter at slope angle

```ruby
MM = 25.4
bld_w = 4000.0; ridge_h = 1500.0; z0 = 3000.0
rafter_t = 50.0; rafter_h = 150.0

slope_len = Math.sqrt((bld_w/2)**2 + ridge_h**2)
angle     = Math.atan2(ridge_h, bld_w / 2)   # radians

model.start_operation("Rafter", true)
grp = model.entities.add_group
grp.layer = model.layers["Стропила"]
e = grp.entities
face = e.add_face(
  [0,            0,            0],
  [rafter_t/MM,  0,            0],
  [rafter_t/MM,  rafter_h/MM,  0],
  [0,            rafter_h/MM,  0]
)
sign = face.normal.z >= 0 ? 1 : -1
face.pushpull(sign * slope_len / MM)

# Rotate to slope angle around Y, then translate to position
rot = Geom::Transformation.rotation(ORIGIN, Y_AXIS, angle)
pos = Geom::Transformation.translation([0, 1000/MM, z0/MM])
grp.transform!(pos * rot)
model.commit_operation
```

## Array of floor joists

```ruby
MM = 25.4
span = 6000.0; width = 4000.0; joist_w = 50.0; joist_h = 200.0; step = 600.0

model.start_operation("Floor joists", true)
parent = model.entities.add_group
parent.layer = model.layers["Лаги пола"]

y = 0.0; i = 0
while y <= width
  joist = make_box(parent.entities, 0, y, 0, span, joist_w, joist_h)
  joist.name = "joist_#{i}"
  y += step; i += 1
end
model.commit_operation
```

## follow_me — profile along a path (e.g. mauerlat around perimeter)

```ruby
MM = 25.4
bld_w = 6000.0; bld_l = 4000.0; beam_w = 150.0; beam_h = 100.0; z0 = 3000.0

model.start_operation("Mauerlat", true)
grp = model.entities.add_group
grp.layer = model.layers["Обвязка"]
e = grp.entities

path = e.add_edges(
  [0,        0,       z0/MM], [bld_w/MM, 0,       z0/MM],
  [bld_w/MM, 0,       z0/MM], [bld_w/MM, bld_l/MM, z0/MM],
  [bld_w/MM, bld_l/MM, z0/MM], [0,       bld_l/MM, z0/MM],
  [0,        bld_l/MM, z0/MM], [0,       0,        z0/MM]
)
profile = e.add_face(
  [0, 0,         z0/MM          ],
  [0, beam_w/MM, z0/MM          ],
  [0, beam_w/MM, (z0+beam_h)/MM ],
  [0, 0,         (z0+beam_h)/MM ]
)
profile.followme(path)
model.commit_operation
```

## Traverse nested groups recursively

```ruby
def each_face(entities, depth = 0, max_depth = 4, &block)
  return if depth > max_depth
  entities.each do |e|
    if e.is_a?(Sketchup::Face)
      block.call(e, depth)
    elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      sub = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
      each_face(sub, depth + 1, max_depth, &block)
    end
  end
end

# Usage
each_face(model.entities) do |face, depth|
  puts "d#{depth}: area #{(face.area * MM**2).round(0)} mm2"
end
```

## Get world-space vertex positions from a nested group

`vertex.position` returns LOCAL coordinates inside the group.
Multiply by the group's transformation to get world coordinates:

```ruby
world_pt = grp.transformation * vertex.position
```

## Move / transform

```ruby
MM = 25.4
# Translate by [dx, dy, dz] in mm
t = Geom::Transformation.translation([dx/MM, dy/MM, dz/MM])
grp.transform!(t)

# Rotate 45° around Z through the group's own center
t = Geom::Transformation.rotation(grp.bounds.center, Z_AXIS, 45.degrees)
grp.transform!(t)

# Scale 2× along X from center
t = Geom::Transformation.scaling(grp.bounds.center, 2.0, 1.0, 1.0)
grp.transform!(t)
```

## Materials

```ruby
mat = model.materials.add("wood")
mat.color = Sketchup::Color.new(180, 120, 60)   # RGB
grp.material = mat
grp.material = nil   # remove
```

## Layers

```ruby
model.layers.add("NewLayer")             # create
model.layers["Кровля"].visible = false   # hide
grp.layer = model.layers["Стены"]        # assign group to layer
model.layers.purge_unused                # clean up after erasing objects
```

## Delete

```ruby
model.find_entity_by_id(id).erase!
```

## Nested components for movable parts

Furniture with doors, drawers, or other parts that should move independently
(e.g. swing open, slide out) needs each part as its own ComponentDefinition,
nested inside the parent. A Group cannot be reused; only ComponentInstance can
share a definition across multiple instances and animations.

```ruby
MM = 25.4
model = Sketchup.active_model
model.start_operation("Cabinet with door", true)

# ----- Cabinet body (Group — single instance) -----
cabinet = model.entities.add_group
cabinet.name = "cabinet_body"
make_box(cabinet.entities, 0, 0, 0, 600, 400, 800)  # 600×400×800 mm

# ----- Door (ComponentDefinition — reusable, can be transformed) -----
door_def = model.definitions.add("cabinet_door")
make_box(door_def.entities, 0, 0, 0, 600, 20, 800)

# Place the door at the front face of the cabinet, with hinge at left edge.
hinge_pos = Geom::Point3d.new(0, 400/MM, 0)  # front face
door_inst = model.entities.add_instance(door_def, Geom::Transformation.new(hinge_pos))
door_inst.name = "front_door"

# To "open" the door: rotate around its hinge axis.
hinge_axis = Geom::Vector3d.new(0, 0, 1)
open_angle = 90.degrees
door_inst.transform!(Geom::Transformation.rotation(hinge_pos, hinge_axis, open_angle))

model.commit_operation
```

Reuse the same `door_def` for multiple identical doors:

```ruby
right_door = model.entities.add_instance(door_def,
  Geom::Transformation.new(Geom::Point3d.new(600/MM, 400/MM, 0)))
```

## Common pitfalls

| Mistake | Fix |
|---|---|
| `model.entities.find_entity_by_id(id)` | Use `model.find_entity_by_id(id)` |
| Passing mm values to API without conversion | Divide by 25.4 |
| Reading API coords as mm without conversion | Multiply by 25.4 |
| `bounds1 + bounds2` | Manually collect min/max across groups |
| No `start_operation` wrapper | Changes can't be undone; always wrap edits |
| `face.pushpull(h/MM)` assuming +Z direction | Check `face.normal.z` sign first (see `make_box` helper) |
| `vertex.position` assumed to be world space | Multiply by `grp.transformation` to get world coords |
| `bounds` of nested sub-group assumed to be world space | Bounds of sub-group are in parent's local space; apply parent's transformation if needed |
| `A.subtract(B)` expecting `A - B` | `Group#subtract` is reversed: returns `B - A`. Call `tool.subtract(target)` to get «target - tool» |
| `Sketchup::Model#undo` | Doesn't exist — use `Sketchup.send_action("editUndo:")` |

## Viewport snapshot via `View#write_image`

For non-destructive screenshots, deep-copy the camera and snapshot the
rendering-options keys you intend to change, mutate, write the image,
then restore. `View#camera=` and `RenderingOptions[]=` are UI state —
they don't enter the undo stack — so you don't need `model.start_operation`.

**Important notes for SketchUp 2026** (verified empirically):

- `Sketchup.send_action("viewIso:")` is **asynchronous** — the camera does
  NOT change before the call returns. Use direct `view.camera =
  Sketchup::Camera.new(eye, target, up)` for synchronous, locale-independent
  preset switching.
- The boolean rendering-options keys `DisplayShaded`, `DrawEdges`, `DrawFaces`
  are **WRITE-REJECTED** (`ArgumentError`). For switching rendering style use
  the `RenderMode` integer enum (`0` Wireframe / `1` Hidden Line / `2` Shaded /
  `3` Textured Shaded / `4` Monochrome / `5` Sketchy / `6` X-Ray).

```ruby
view  = Sketchup.active_model.active_view
model = view.model

# --- snapshot (deep copy — protects against future API changes that might
# return live references; iter-1 verified `view.camera` returns a fresh
# wrapper today, but the deep copy is defence-in-depth) ---
c = view.camera
snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)
snap_camera.perspective = c.perspective?
if c.perspective?
  snap_camera.fov = c.fov
else
  snap_camera.height = c.height
end
ro_keys = ["RenderMode"]
snap_ro = ro_keys.map { |k| [k, model.rendering_options[k]] }.to_h

# --- mutate (direct camera assignment + RenderMode enum) ---
bb     = model.bounds
center = bb.center
dist   = (bb.diagonal.zero? ? 1000.0 : bb.diagonal) * 1.5
offset = Geom::Vector3d.new(1, -1, 1)
offset.length = dist
eye    = center + offset
view.camera = Sketchup::Camera.new(eye, center, Geom::Vector3d.new(0, 0, 1))
model.rendering_options["RenderMode"] = 2  # 2 = Shaded
view.zoom_extents

require "tempfile"
Tempfile.create(["snap_", ".png"]) do |tmp|
  tmp.close
  ok = view.write_image(
    filename: tmp.path,
    width: 800, height: 450,
    antialias: true,
    compression: 1.0,             # PNG is always lossless; 1.0 = strongest compression
    transparent: false,
  )
  raise "write_image failed" unless ok

  bytes = File.binread(tmp.path)
  # ... use bytes (Base64.strict_encode64 for transport) ...
end                                 # Tempfile auto-deletes here

# --- restore ---
view.camera = snap_camera
snap_ro.each { |k, v| model.rendering_options[k] = v }
```

Used internally by `Handlers::View.viewport_screenshot` (see
`su_mcp/su_mcp/handlers/view.rb`).

# Пересборка ящиков (дно 12, шканты 6×30) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Примечание проекта:** предыдущие фазы исполнялись в режиме **inline** (superpowers:executing-plans) по выбору пользователя — уточнить при старте.

**Goal:** В живой модели SketchUp перестроить коробки всех 10 ящиков (A×2, B×3, C×2, D×3) под новую конструкцию — дно 12 накладное снизу, стенки 228 на шкантах 6×30, — и высверлить присадку (240 вырезов Ø6 + 648 гайд-точек на 4 тегах в папке «Присадка ящиков») по спеке `docs/superpowers/specs/2026-07-12-bed-drawers-rebuild-design.md`.

**Architecture:** Последовательность самодостаточных `eval_ruby`-чанков: T0 — папка+теги; R1–R10 — один ящик за чанк (одна операция: снос 5 старых деталей коробки → постройка 5 новых → пересоздание разметки направляющих на боковинах → 24 шкантовых выреза → шурупные гайд-точки → финализация). Чанки data-driven: общая Прелюдия-R + общий RUN-блок, меняется только блок параметров `P`. Каждый чанк возвращает JSON-отчёт; исполнитель сверяет с Expected таска.

**Tech Stack:** SketchUp MCP (`get_version`, `list_components`, `list_layers`, `eval_ruby`, `undo`, `get_viewport_screenshot`), SketchUp Ruby API (`Entities#add_group/add_face/add_circle/add_cline/add_cpoint`, `Face#pushpull`, `Layers#add_folder`), рецепты `docs/sketchup-ruby-cookbook.md`.

## Global Constraints

- Все размеры — **мм**, координаты в таблицах — **мировые фактические** (у выдвинутых ящиков уже +350 по Y); в Ruby деление на 25.4 только в хелперах.
- Один чанк = одна операция `model.start_operation` → `commit_operation`, `abort_operation` в rescue; `puts` не виден — чанк заканчивается JSON-строкой (`result` последним выражением).
- Чанки самодостаточны: «Прелюдия-R» + блок `P` + «RUN-блок» склеиваются в один скрипт. Подавать без сокращений.
- Порог всех сверок длин/bbox — **0,2 мм** (`TOL`); 1e-6″ запрещён (ложные срабатывания на шум ленивого пересчёта bbox). Объёмные сверки — ±5 мм³.
- **Solid-tools запрещены** (пересоздают группу — погибнут guide-точки); резать только `add_circle` + `pushpull` внутри `definition.entities`.
- **Врезной `pushpull` уничтожает исходный Face** — пол ищется заново геометрически (уже встроено в `drill` Прелюдии-R; ledger «Cam Task 3»).
- Перед мутацией узла — assert «накопленный трансформ = чистая трансляция» (`assert_translation`).
- Объёмы `Group#volume` — кубические дюймы → ×25.4³. Объём выреза считать по 24-сегментному полигону (`poly_area`), не по π·r².
- ⚠ Пересборка боковин убивает разметку «Присадка» в их definitions — RUN-блок пересоздаёт её в том же чанке (тег «Присадка», ось Z 160,5; мировые координаты разметки не меняются).
- Существующие теги/видимость не трогать вне операций; `model.save` НЕ вызывать — сохраняет пользователь.
- `ok:false` — чанк откатился сам (`abort`); MCP `undo` — ровно один и только для закоммиченного, но не прошедшего сверку чанка.
- При любом расхождении preflight/отчётов с Expected: **СТОП**, описать расхождение, спросить пользователя. Координаты в чанках без пересчёта матрицы конфликтов не менять (шканты Z 90/130/240 разведены с полосой направляющей 138–183 и шурупами дна ≤ Z 82).
- Ledger `.superpowers/sdd/progress.md` — запись «Drawer Task N: …» после каждого таска.
- Git в этой фазе не меняется (исполнение — только модель + ledger).

---

## Справочник фазы

### Константы конструкции (мировые мм, закрытое положение)

| Что | Значение |
|---|---|
| Коробка по Y | 188–938; перед (`front`, у фасада) 926–938, зад (`back`) 188–200 |
| Дно | Z 40–52, наружный габарит X0..X1 × Y 188–938 |
| Стенки | Z 52–280 (высота 228) |
| Оси шкантов | Y 932 (front) / Y 194 (back); Z **90 / 130 / 240**; глубины: пласть боковины 9, торец переда/зада 22 |
| Шурупы дна: под боковинами | X = X0+6 / X1−6; Y **238 / 455 / 671 / 888** |
| Шурупы дна: под перед/зад | Y 932 / 194; X = X0 + `fb_offs` |
| Шурупы фасада | Y-устья: 926 (пласть front) и 938 (тыл фасада); Z **100 / 230**; X = X0 + `fc_offs` |
| Разметка направляющих (тег «Присадка») | наружные пласти боковин X0 и X1; линия Y 188–938 @ Z 160,5; точки Y **902 / 614 / 262** |
| Выдвинутые ящики | dy = +350 по Y ко ВСЕМ Y-величинам (уже учтено в Expected) |
| Материал новых деталей | `MCP Plywood`, тег `Ящики` |

### Параметры ящиков

| # | node (path) | X0 | X1 | dy | fb_offs (от X0) | fc_offs (от X0) |
|---|---|---|---|---|---|---|
| R1 | Bed_A / A.drawer1 | 30.5 | 1006.5 | 350 | 62, 275, 488, 701, 914 | 188, 488, 788 |
| R2 | Bed_A / A.drawer2 | 1049.5 | 2025.5 | 0 | 62, 275, 488, 701, 914 | 188, 488, 788 |
| R3 | Bed_B / B.drawer1 | 2686.5 | 3322.5 | 0 | 68, 318, 568 | 168, 468 |
| R4 | Bed_B / B.drawer2 | 3365.5 | 4001.5 | 350 | 68, 318, 568 | 168, 468 |
| R5 | Bed_B / B.drawer3 | 4044.5 | 4680.5 | 0 | 68, 318, 568 | 168, 468 |
| R6 | Bed_C / C.drawer1 | 5342.5 | 6309.5 | 350 | 62, 273, 483.5, 694, 905 | 183.5, 483.5, 783.5 |
| R7 | Bed_C / C.drawer2 | 6370.5 | 7337.5 | 0 | 62, 273, 483.5, 694, 905 | 183.5, 483.5, 783.5 |
| R8 | Bed_D / D.drawer1 | 7998.5 | 8623.5 | 0 | 62.5, 312.5, 562.5 | 162.5, 462.5 |
| R9 | Bed_D / D.drawer2 | 8684.5 | 9307.5 | 350 | 62, 311.5, 561 | 161.5, 461.5 |
| R10 | Bed_D / D.drawer3 | 9368.5 | 9993.5 | 0 | 62.5, 312.5, 562.5 | 162.5, 462.5 |

Имена деталей: `<node>.side_L/.side_R/.front/.back/.bottom` (сносятся и строятся заново), `<node>.facade` (не трогается, получает точки пилотов), `<node>.slide_L/.slide_R` (не трогаются). Всего детей узла: 8 — до и после.

### Формулы Expected (мировые фактические; dy уже прибавлен к Y)

- `bottom` [X0, 188+dy, 40, X1, 938+dy, 52]; объём = (X1−X0)×750×12 мм³
- `side_L` [X0, 188+dy, 52, X0+12, 938+dy, 280]; `side_R` [X1−12, …, X1, …]; объём каждой 2 052 000 − 1509.4 = **2 050 490.6**
- `front` [X0+12, 926+dy, 52, X1−12, 938+dy, 280]; `back` [X0+12, 188+dy, 52, X1−12, 200+dy, 280]; объём = (X1−X0−24)×228×12 − **3689.7**
- Вырезы: боковина 6×Ø6×9 (dV 1509.43), front/back 6×Ø6×22 (dV 3689.72), bottom/facade 0
- Точки (pts) по деталям: side по 6+4=10; front 6+n_fb+n_fc; back 6+n_fb; bottom 8+2·n_fb; facade n_fc
  (n_fb = 5, n_fc = 6 для A/C; n_fb = 3, n_fc = 4 для B/D)
- Разметка: на каждой боковине 1 cline + 3 cpoint тега «Присадка»

### Объёмы по кроватям (мм³)

| Кровать | bottom | front/back (каждая) |
|---|---|---|
| A (976) | 8 784 000 | 2 600 982.3 |
| B (636) | 5 724 000 | 1 670 742.3 |
| C (967) | 8 703 000 | 2 576 358.3 |
| D1/D3 (625) | 5 625 000 | 1 640 646.3 |
| D2 (623) | 5 607 000 | 1 635 174.3 |

### Прелюдия-R (вставлять целиком вместо `# --- PRELUDE-R ---`)

```ruby
require "json"
model = Sketchup.active_model
MM  = 25.4
TOL = 0.2 # мм

MAT     = "MCP Plywood"
T_DP    = "Ø6×9 шкант пласть ящика"
T_DT    = "Ø6×22 шкант торец ящика"
T_THRU  = "Ø4,5 сквозное ящика"
T_PIL   = "Ø3 пилот ящика"
TAG_NAMES = [T_DP, T_DT, T_THRU, T_PIL]

DZ     = [90.0, 130.0, 240.0]        # Z осей шкантов
FZ     = [100.0, 230.0]              # Z рядов фасадных шурупов
SIDE_Y = [238.0, 455.0, 671.0, 888.0] # Y шурупов дна под боковинами (закрыто)
MARK_Y = [902.0, 614.0, 262.0]       # точки разметки направляющих (закрыто)

find_child = lambda do |ents, nm|
  g = ents.grep(Sketchup::Group).find { |x| x.name == nm }
  raise "child not found: #{nm}" unless g
  g
end

resolve = lambda do |path|
  ents = model.entities
  tr = Geom::Transformation.new
  g = nil
  path.each do |nm|
    g = find_child.call(ents, nm)
    tr = tr * g.transformation
    ents = g.entities
  end
  [g, tr]
end

assert_translation = lambda do |tr, label|
  a = tr.to_a
  ok = [[0, 1.0], [1, 0.0], [2, 0.0], [4, 0.0], [5, 1.0], [6, 0.0],
        [8, 0.0], [9, 0.0], [10, 1.0], [15, 1.0]].all? { |i, v| (a[i] - v).abs < 1e-6 }
  raise "transform is not a pure translation: #{label}" unless ok
end

count_groups = lambda do |ents|
  gs = ents.grep(Sketchup::Group)
  gs.length + gs.map { |g| count_groups.call(g.entities) }.sum
end

wpt = lambda { |x, y, z| Geom::Point3d.new(x / MM, y / MM, z / MM) }
AX  = { x: Geom::Vector3d.new(1, 0, 0), y: Geom::Vector3d.new(0, 1, 0), z: Geom::Vector3d.new(0, 0, 1) }
poly_area = lambda { |dia| 0.5 * 24 * (dia / 2.0)**2 * Math.sin(2 * Math::PI / 24) } # мм²

tags = {}
load_tags = lambda do
  (TAG_NAMES + ["Присадка", "Ящики"]).each do |nm|
    l = model.layers[nm]
    raise "tag missing (run chunk T0 first): #{nm}" unless l
    tags[nm] = l
  end
end

wbox = lambda do |d, tr|
  b = d.bounds
  [tr * b.min, tr * b.max].flat_map { |p| p.to_a.map { |v| (v * MM).round(1) } }
end

parts_cache = {}
reg_part = lambda do |key, g, tr|
  raise "definition shared: #{key}" unless g.definition.count_instances == 1
  v0 = g.volume
  raise "not a solid: #{key}" unless v0.is_a?(Numeric) && v0 > 0
  parts_cache[key] = { part: g, tr: tr, inv: tr.inverse, d: g.definition,
                       vol0: v0, b0: g.definition.bounds,
                       delta_exp: 0.0, cuts: 0, pts: 0 }
end

mk_box = lambda do |node, inv_node, name, w0, w1|
  g = node.entities.add_group
  pts = [[w0[0], w0[1]], [w1[0], w0[1]], [w1[0], w1[1]], [w0[0], w1[1]]]
        .map { |x, y| inv_node * wpt.call(x, y, w0[2]) }
  f = g.entities.add_face(pts)
  raise "face failed: #{name}" unless f
  h = (w1[2] - w0[2]) / MM
  f.pushpull(f.normal.z > 0 ? h : -h)
  g.name = name
  g.material = model.materials[MAT] || (raise "material missing: #{MAT}")
  g.layer = tags["Ящики"]
  g
end

# job = { part: "side_L"…, ax: :x|:y|:z, s: +1|-1 (наружная нормаль грани устья),
#         c: [x,y,z мир мм], dia:, depth:, tag: }
J = lambda do |part, ax, s, x, y, z, dia, depth, tag|
  { part: part, ax: ax, s: s, c: [x.to_f, y.to_f, z.to_f],
    dia: dia.to_f, depth: depth.to_f, tag: tag }
end

drill = lambda do |job|
  rec = parts_cache[job[:part]] || (raise "part not registered: #{job[:part]}")
  d = rec[:d]
  n = AX[job[:ax]].clone
  n.reverse! if job[:s] < 0
  cl = rec[:inv] * wpt.call(*job[:c])
  edges = d.entities.add_circle(cl, n, (job[:dia] / 2.0) / MM, 24)
  raise "circle failed @#{job[:c]}" if edges.nil? || edges.empty?
  face = edges.first.faces.min_by(&:area)
  raise "no disk face @#{job[:c]}" unless face
  raise "disk normal off-axis @#{job[:c]}" unless face.normal.parallel?(n)
  sgn = face.normal.samedirection?(n) ? -1 : 1
  face.pushpull(sgn * job[:depth] / MM)
  # врезной pushpull уничтожил Face — пол ищем заново геометрически
  ax_in = n.clone
  ax_in.reverse!
  floors = d.entities.grep(Sketchup::Face).map { |f|
    next nil unless f.normal.parallel?(n)
    t = ((f.vertices.first.position - cl) % ax_in) * MM
    next nil unless t > TOL && t <= job[:depth] + TOL
    ctr = cl.offset(ax_in, t / MM)
    next nil unless f.classify_point(ctr) == Sketchup::Face::PointInside
    t
  }.compact
  raise "blind hole lost its floor @#{job[:c]}" if floors.empty?
  raise "depth #{floors.min.round(2)} != #{job[:depth]} @#{job[:c]}" if (floors.min - job[:depth]).abs > TOL
  cp = d.entities.add_cpoint(cl)
  cp.layer = tags[job[:tag]]
  rec[:delta_exp] += poly_area.call(job[:dia]) * job[:depth]
  rec[:cuts] += 1
  rec[:pts] += 1
end

point_only = lambda do |key, x, y, z, tag|
  rec = parts_cache[key] || (raise "part not registered: #{key}")
  cp = rec[:d].entities.add_cpoint(rec[:inv] * wpt.call(x, y, z))
  cp.layer = tags[tag]
  rec[:pts] += 1
end

mark_side = lambda do |key, x, y1, y2, pts_y|
  rec = parts_cache[key] || (raise "part not registered: #{key}")
  d = rec[:d]
  cl = d.entities.add_cline(rec[:inv] * wpt.call(x, y1, 160.5),
                            rec[:inv] * wpt.call(x, y2, 160.5))
  cl.layer = tags["Присадка"]
  pw = pts_y.map do |y|
    cp = d.entities.add_cpoint(rec[:inv] * wpt.call(x, y, 160.5))
    cp.layer = tags["Присадка"]
    (rec[:tr] * cp.position).to_a.map { |v| (v * MM).round(1) }
  end
  lw = [cl.start, cl.end].map { |p| (rec[:tr] * p).to_a.map { |v| (v * MM).round(1) } }
  { "x" => x, "line_world" => lw, "points_world" => pw }
end

finalize = lambda do
  parts_cache.map do |key, rec|
    v1 = rec[:part].volume
    raise "not a solid after cuts: #{key}" unless v1.is_a?(Numeric) && v1 > 0
    delta_fact = (rec[:vol0] - v1) * MM**3
    raise "volume mismatch #{key}: fact #{delta_fact.round(2)} exp #{rec[:delta_exp].round(2)}" if (delta_fact - rec[:delta_exp]).abs > 5.0
    b1 = rec[:d].bounds
    bb_ok = (b1.min - rec[:b0].min).length * MM < TOL && (b1.max - rec[:b0].max).length * MM < TOL
    raise "bbox changed after cuts: #{key}" unless bb_ok
    { "part" => key,
      "bbox_mm" => wbox.call(rec[:d], rec[:tr]),
      "vol_mm3" => (v1 * MM**3).round(1),
      "cuts" => rec[:cuts], "pts" => rec[:pts],
      "cl" => rec[:d].entities.grep(Sketchup::ConstructionLine).size,
      "cp" => rec[:d].entities.grep(Sketchup::ConstructionPoint).size }
  end
end
```

### RUN-блок (вставлять целиком вместо `# --- RUN-R ---`; перед ним — блок `P` таска)

```ruby
result = begin
  model.start_operation("MCP: Ящики — #{P[:node].last}", true)
  load_tags.call
  node, tr_node = resolve.call(P[:node])
  assert_translation.call(tr_node, P[:node].join("/"))
  raise "node definition shared" unless node.definition.count_instances == 1
  nb0 = node.definition.bounds
  nb0_min = nb0.min.clone
  nb0_max = nb0.max.clone
  base = P[:node].last
  dy = P[:dy]
  x0 = P[:x0]
  x1 = P[:x1]
  y0 = 188.0 + dy
  y1 = 938.0 + dy
  yf  = 932.0 + dy   # ось шкантов/шурупов front
  yb  = 194.0 + dy   # ось шкантов/шурупов back
  yfi = 926.0 + dy   # внутренняя пласть front (устья фасадных сквозных)
  yft = 938.0 + dy   # тыл фасада (устья пилотов фасада)

  # --- 1) снос 5 старых деталей коробки ---
  old_rep = {}
  %w[side_L side_R front back bottom].each do |suf|
    g = find_child.call(node.entities, "#{base}.#{suf}")
    old_rep[suf] = wbox.call(g.definition, tr_node * g.transformation)
    g.erase!
  end
  left = node.entities.grep(Sketchup::Group)
             .select { |g| %w[side_L side_R front back bottom].any? { |s| g.name == "#{base}.#{s}" } }
  raise "old parts still present" unless left.empty?

  # --- 2) постройка 5 новых деталей ---
  inv_node = tr_node.inverse
  spec = {
    "bottom" => [[x0, y0, 40.0],        [x1, y1, 52.0]],
    "side_L" => [[x0, y0, 52.0],        [x0 + 12, y1, 280.0]],
    "side_R" => [[x1 - 12, y0, 52.0],   [x1, y1, 280.0]],
    "front"  => [[x0 + 12, yfi, 52.0],  [x1 - 12, yft, 280.0]],
    "back"   => [[x0 + 12, y0, 52.0],   [x1 - 12, 200.0 + dy, 280.0]]
  }
  spec.each do |suf, (w0, w1)|
    g = mk_box.call(node, inv_node, "#{base}.#{suf}", w0, w1)
    tr_full = tr_node * g.transformation
    assert_translation.call(tr_full, "#{base}.#{suf}")
    reg_part.call(suf, g, tr_full)
  end
  fg = find_child.call(node.entities, "#{base}.facade")
  tr_f = tr_node * fg.transformation
  assert_translation.call(tr_f, "#{base}.facade")
  reg_part.call("facade", fg, tr_f)

  # --- 3) разметка направляющих (тег «Присадка», как была на старых боковинах) ---
  marks = [
    mark_side.call("side_L", x0, y0, y1, MARK_Y.map { |y| y + dy }),
    mark_side.call("side_R", x1, y0, y1, MARK_Y.map { |y| y + dy })
  ]

  # --- 4) шканты 6×30: 24 выреза ---
  [yf, yb].each do |yy|
    fb = (yy == yf) ? "front" : "back"
    DZ.each do |z|
      drill.call(J.call("side_L", :x, +1, x0 + 12, yy, z, 6.0, 9.0,  T_DP))
      drill.call(J.call("side_R", :x, -1, x1 - 12, yy, z, 6.0, 9.0,  T_DP))
      drill.call(J.call(fb,       :x, -1, x0 + 12, yy, z, 6.0, 22.0, T_DT))
      drill.call(J.call(fb,       :x, +1, x1 - 12, yy, z, 6.0, 22.0, T_DT))
    end
  end

  # --- 5) шурупные гайд-точки ---
  SIDE_Y.each do |sy|
    [[x0 + 6, "side_L"], [x1 - 6, "side_R"]].each do |sx, sname|
      point_only.call("bottom", sx, sy + dy, 40.0, T_THRU)
      point_only.call(sname,    sx, sy + dy, 52.0, T_PIL)
    end
  end
  P[:fb_offs].each do |off|
    [[yf, "front"], [yb, "back"]].each do |yy, nm|
      point_only.call("bottom", x0 + off, yy, 40.0, T_THRU)
      point_only.call(nm,       x0 + off, yy, 52.0, T_PIL)
    end
  end
  P[:fc_offs].each do |off|
    FZ.each do |z|
      point_only.call("front",  x0 + off, yfi, z, T_THRU)
      point_only.call("facade", x0 + off, yft, z, T_PIL)
    end
  end

  # --- 6) финализация ---
  parts_rep = finalize.call
  nb1 = node.definition.bounds
  nb_ok = (nb1.min - nb0_min).length * MM < TOL && (nb1.max - nb0_max).length * MM < TOL
  raise "node bbox changed" unless nb_ok
  children = node.entities.grep(Sketchup::Group).map(&:name).sort
  gtotal = count_groups.call(model.entities)
  model.commit_operation
  JSON.generate({ "ok" => true, "node" => base,
                  "node_bbox" => wbox.call(node.definition, tr_node),
                  "children" => children, "old" => old_rep,
                  "marks" => marks, "parts" => parts_rep,
                  "groups_total" => gtotal })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message,
                  "backtrace" => (e.backtrace || []).first(3) })
end
result
```

Сверка отчёта чанка (одинакова для R1–R10, числа — из таблиц таска):

1. `ok` == true; `groups_total` == **233**; `children` — 8 имён (5 пересозданных + facade + slide_L/R).
2. `node_bbox` == узловому bbox из preflight (Task 1) — не изменился.
3. `parts[*].bbox_mm` == Expected bbox таска (все |Δ| ≤ 0,2).
4. `parts[*].vol_mm3` == Expected объёмам (±5 мм³); `cuts`/`pts` == Expected.
5. `marks` == Expected разметке (линия и 3 точки на каждой боковине).
6. `parts["facade"].cl == 0`, `cp == n_fc`; у боковин `cl == 1`, `cp == 3 + 10` (3 разметки + 10 гайдов).

---

## Задачи

### Task 1: Preflight (read-only)

**Files:** нет (живая модель); ledger `.superpowers/sdd/progress.md`.
**Interfaces:** Produces — подтверждённые фактические bbox/имена/материалы 10 ящиков и видимость тегов `before` для Task 7.

- [ ] **Step 1: Совместимость и модель.** `get_version` → python 0.3.0 ↔ ruby 0.3.0 compatible. `list_components` (recursive=true) → **233 группы, truncated=false**. `list_layers` → **16 слоёв**, папка «Присадка D» (тегов из TAG_NAMES ещё нет).
- [ ] **Step 2: Eval-гейт.** `eval_ruby("1+1")` → 2.
- [ ] **Step 3: Зонд ящиков (read-only eval, БЕЗ операции).** Скрипт: для каждого узла из таблицы параметров вывести: имена детей; мировой bbox (`definition.bounds` × накопленный трансформ) каждой из 8 деталей; материал (`material&.display_name`) 5 деталей коробки; счёт cline/cpoint тега «Присадка» в обеих боковинах; видимость всех слоёв. Сверить:
  - Имена детей: `<node>.side_L/.side_R/.front/.back/.bottom/.facade/.slide_L/.slide_R`.
  - Старые bbox (формулы, dy уже в Y): `side_L` [X0, 188+dy, 40, X0+12, 938+dy, 280]; `side_R` [X1−12, …, X1, …]; `front` [X0+12, 926+dy, 40, X1−12, 938+dy, 280]; `back` [X0+12, 188+dy, 40, X1−12, 200+dy, 280]; `bottom` [X0+7, 194+dy, 53, X1−7, 930+dy, 59] — старая конструкция: стенки от Z 40, дно 6 в пазу.
  - Материал всех деталей коробки — `MCP Plywood`.
  - В каждой боковине ровно 1 cline + 3 cpoint тега «Присадка».
  - Зафиксировать видимость слоёв (`before`) и узловые bbox для Task 7 / сверок R-чанков.
- [ ] **Step 4: СТОП-правило.** Любое расхождение (bbox >0,2 мм, другие имена/материалы, не 233 группы) — остановиться, доложить пользователю, НЕ продолжать.
- [ ] **Step 5: Ledger-запись** «Drawer Task 1: preflight …» (итоги, видимость before).

### Task 2: Чанк T0 — папка «Присадка ящиков» + 4 тега

**Files:** нет.
**Interfaces:** Produces — теги `Ø6×9 шкант пласть ящика`, `Ø6×22 шкант торец ящика`, `Ø4,5 сквозное ящика`, `Ø3 пилот ящика` (нужны всем R-чанкам).

- [ ] **Step 1: Исполнить чанк T0** (самодостаточный, прелюдия не нужна):

```ruby
require "json"
model = Sketchup.active_model
TAG_NAMES = ["Ø6×9 шкант пласть ящика", "Ø6×22 шкант торец ящика",
             "Ø4,5 сквозное ящика", "Ø3 пилот ящика"]
count_groups = lambda do |ents|
  gs = ents.grep(Sketchup::Group)
  gs.length + gs.map { |g| count_groups.call(g.entities) }.sum
end
result = begin
  raise "tag already exists" if TAG_NAMES.any? { |nm| model.layers[nm] }
  model.start_operation("MCP: Ящики T0 — теги присадки", true)
  folder = model.layers.add_folder("Присадка ящиков")
  TAG_NAMES.each { |nm| folder.add_layer(model.layers.add(nm)) }
  model.commit_operation
  JSON.generate({ "ok" => true, "folder" => folder.name,
                  "in_folder" => folder.layers.map(&:name).sort,
                  "layers_total" => model.layers.size,
                  "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message })
end
result
```

- [ ] **Step 2: Сверка.** `ok:true`; `in_folder` — 4 имени; `layers_total` == **20**; `groups_total` == **233**.
- [ ] **Step 3: Ledger-запись** «Drawer Task 2: …».

### Task 3: Bed_A — чанки R1 (A.drawer1) и R2 (A.drawer2)

**Files:** нет.
**Interfaces:** Consumes — теги Task 2; bbox/before из Task 1. Produces — перестроенные A.drawer1/A.drawer2.

- [ ] **Step 1: Чанк R1.** Склеить: Прелюдия-R + блок `P` + RUN-блок; исполнить `eval_ruby`:

```ruby
# --- PRELUDE-R ---
P = { node: ["Bed_A", "A.drawer1"], x0: 30.5, x1: 1006.5, dy: 350.0,
      fb_offs: [62.0, 275.0, 488.0, 701.0, 914.0],
      fc_offs: [188.0, 488.0, 788.0] }
# --- RUN-R ---
```

- [ ] **Step 2: Сверка R1 по Expected** (порядок сверки — «Сверка отчёта чанка» выше):

| part | bbox_mm (мир, выдвинут +350) | vol_mm3 | cuts | pts |
|---|---|---|---|---|
| bottom | [30.5, 538, 40, 1006.5, 1288, 52] | 8 784 000 | 0 | 18 |
| side_L | [30.5, 538, 52, 42.5, 1288, 280] | 2 050 490.6 | 6 | 10 |
| side_R | [994.5, 538, 52, 1006.5, 1288, 280] | 2 050 490.6 | 6 | 10 |
| front | [42.5, 1276, 52, 994.5, 1288, 280] | 2 600 982.3 | 6 | 17 |
| back | [42.5, 538, 52, 994.5, 550, 280] | 2 600 982.3 | 6 | 11 |
| facade | == bbox из preflight (не менялся) | == preflight | 0 | 6 |

marks: side_L X 30.5, side_R X 1006.5; line Y 538–1288 @ Z 160.5; points Y [1252, 964, 612].

- [ ] **Step 3: Чанк R2.** Тот же скрипт с блоком:

```ruby
P = { node: ["Bed_A", "A.drawer2"], x0: 1049.5, x1: 2025.5, dy: 0.0,
      fb_offs: [62.0, 275.0, 488.0, 701.0, 914.0],
      fc_offs: [188.0, 488.0, 788.0] }
```

- [ ] **Step 4: Сверка R2:**

| part | bbox_mm | vol_mm3 | cuts | pts |
|---|---|---|---|---|
| bottom | [1049.5, 188, 40, 2025.5, 938, 52] | 8 784 000 | 0 | 18 |
| side_L | [1049.5, 188, 52, 1061.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| side_R | [2013.5, 188, 52, 2025.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| front | [1061.5, 926, 52, 2013.5, 938, 280] | 2 600 982.3 | 6 | 17 |
| back | [1061.5, 188, 52, 2013.5, 200, 280] | 2 600 982.3 | 6 | 11 |
| facade | == preflight | == preflight | 0 | 6 |

marks: X 1049.5 / 2025.5; line Y 188–938; points Y [902, 614, 262].

- [ ] **Step 5: Ledger-запись** «Drawer Task 3: …» (счётчики, отклонения 0.0, группы 233).

### Task 4: Bed_B — чанки R3, R4, R5

**Files:** нет.
**Interfaces:** Consumes — Task 2. Produces — перестроенные B.drawer1..3.

- [ ] **Step 1: Чанк R3** (Прелюдия-R + P + RUN-R):

```ruby
P = { node: ["Bed_B", "B.drawer1"], x0: 2686.5, x1: 3322.5, dy: 0.0,
      fb_offs: [68.0, 318.0, 568.0], fc_offs: [168.0, 468.0] }
```

- [ ] **Step 2: Сверка R3:**

| part | bbox_mm | vol_mm3 | cuts | pts |
|---|---|---|---|---|
| bottom | [2686.5, 188, 40, 3322.5, 938, 52] | 5 724 000 | 0 | 14 |
| side_L | [2686.5, 188, 52, 2698.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| side_R | [3310.5, 188, 52, 3322.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| front | [2698.5, 926, 52, 3310.5, 938, 280] | 1 670 742.3 | 6 | 13 |
| back | [2698.5, 188, 52, 3310.5, 200, 280] | 1 670 742.3 | 6 | 9 |
| facade | == preflight | == preflight | 0 | 4 |

marks: X 2686.5 / 3322.5; line Y 188–938; points Y [902, 614, 262].

- [ ] **Step 3: Чанк R4** (выдвинут):

```ruby
P = { node: ["Bed_B", "B.drawer2"], x0: 3365.5, x1: 4001.5, dy: 350.0,
      fb_offs: [68.0, 318.0, 568.0], fc_offs: [168.0, 468.0] }
```

- [ ] **Step 4: Сверка R4:** bbox как R3 + (X: +679; Y: +350): bottom [3365.5, 538, 40, 4001.5, 1288, 52]; side_L [3365.5, 538, 52, 3377.5, 1288, 280]; side_R [3989.5, 538, 52, 4001.5, 1288, 280]; front [3377.5, 1276, 52, 3989.5, 1288, 280]; back [3377.5, 538, 52, 3989.5, 550, 280]. Объёмы/cuts/pts — как R3. marks: X 3365.5 / 4001.5; line Y 538–1288; points Y [1252, 964, 612].

- [ ] **Step 5: Чанк R5:**

```ruby
P = { node: ["Bed_B", "B.drawer3"], x0: 4044.5, x1: 4680.5, dy: 0.0,
      fb_offs: [68.0, 318.0, 568.0], fc_offs: [168.0, 468.0] }
```

- [ ] **Step 6: Сверка R5:** bottom [4044.5, 188, 40, 4680.5, 938, 52]; side_L [4044.5, 188, 52, 4056.5, 938, 280]; side_R [4668.5, 188, 52, 4680.5, 938, 280]; front [4056.5, 926, 52, 4668.5, 938, 280]; back [4056.5, 188, 52, 4668.5, 200, 280]. Объёмы/cuts/pts — как R3. marks: X 4044.5 / 4680.5; закрытые Y.

- [ ] **Step 7: Ledger-запись** «Drawer Task 4: …».

### Task 5: Bed_C — чанки R6, R7

**Files:** нет.
**Interfaces:** Consumes — Task 2. Produces — перестроенные C.drawer1..2.

- [ ] **Step 1: Чанк R6** (выдвинут):

```ruby
P = { node: ["Bed_C", "C.drawer1"], x0: 5342.5, x1: 6309.5, dy: 350.0,
      fb_offs: [62.0, 273.0, 483.5, 694.0, 905.0],
      fc_offs: [183.5, 483.5, 783.5] }
```

- [ ] **Step 2: Сверка R6:**

| part | bbox_mm (выдвинут +350) | vol_mm3 | cuts | pts |
|---|---|---|---|---|
| bottom | [5342.5, 538, 40, 6309.5, 1288, 52] | 8 703 000 | 0 | 18 |
| side_L | [5342.5, 538, 52, 5354.5, 1288, 280] | 2 050 490.6 | 6 | 10 |
| side_R | [6297.5, 538, 52, 6309.5, 1288, 280] | 2 050 490.6 | 6 | 10 |
| front | [5354.5, 1276, 52, 6297.5, 1288, 280] | 2 576 358.3 | 6 | 17 |
| back | [5354.5, 538, 52, 6297.5, 550, 280] | 2 576 358.3 | 6 | 11 |
| facade | == preflight | == preflight | 0 | 6 |

marks: X 5342.5 / 6309.5; line Y 538–1288; points Y [1252, 964, 612].

- [ ] **Step 3: Чанк R7:**

```ruby
P = { node: ["Bed_C", "C.drawer2"], x0: 6370.5, x1: 7337.5, dy: 0.0,
      fb_offs: [62.0, 273.0, 483.5, 694.0, 905.0],
      fc_offs: [183.5, 483.5, 783.5] }
```

- [ ] **Step 4: Сверка R7:** bottom [6370.5, 188, 40, 7337.5, 938, 52]; side_L [6370.5, 188, 52, 6382.5, 938, 280]; side_R [7325.5, 188, 52, 7337.5, 938, 280]; front [6382.5, 926, 52, 7325.5, 938, 280]; back [6382.5, 188, 52, 7325.5, 200, 280]. Объёмы/cuts/pts — как R6. marks: X 6370.5 / 7337.5; закрытые Y.

- [ ] **Step 5: Ledger-запись** «Drawer Task 5: …».

### Task 6: Bed_D — чанки R8, R9, R10

**Files:** нет.
**Interfaces:** Consumes — Task 2. Produces — перестроенные D.drawer1..3.

- [ ] **Step 1: Чанк R8:**

```ruby
P = { node: ["Bed_D", "D.drawer1"], x0: 7998.5, x1: 8623.5, dy: 0.0,
      fb_offs: [62.5, 312.5, 562.5], fc_offs: [162.5, 462.5] }
```

- [ ] **Step 2: Сверка R8:**

| part | bbox_mm | vol_mm3 | cuts | pts |
|---|---|---|---|---|
| bottom | [7998.5, 188, 40, 8623.5, 938, 52] | 5 625 000 | 0 | 14 |
| side_L | [7998.5, 188, 52, 8010.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| side_R | [8611.5, 188, 52, 8623.5, 938, 280] | 2 050 490.6 | 6 | 10 |
| front | [8010.5, 926, 52, 8611.5, 938, 280] | 1 640 646.3 | 6 | 13 |
| back | [8010.5, 188, 52, 8611.5, 200, 280] | 1 640 646.3 | 6 | 9 |
| facade | == preflight | == preflight | 0 | 4 |

marks: X 7998.5 / 8623.5; line Y 188–938; points Y [902, 614, 262].

- [ ] **Step 3: Чанк R9** (выдвинут; ширина 623):

```ruby
P = { node: ["Bed_D", "D.drawer2"], x0: 8684.5, x1: 9307.5, dy: 350.0,
      fb_offs: [62.0, 311.5, 561.0], fc_offs: [161.5, 461.5] }
```

- [ ] **Step 4: Сверка R9:** bottom [8684.5, 538, 40, 9307.5, 1288, 52] vol **5 607 000**; side_L [8684.5, 538, 52, 8696.5, 1288, 280]; side_R [9295.5, 538, 52, 9307.5, 1288, 280]; front [8696.5, 1276, 52, 9295.5, 1288, 280] vol **1 635 174.3**; back [8696.5, 538, 52, 9295.5, 550, 280] vol 1 635 174.3. cuts/pts — как R8. marks: X 8684.5 / 9307.5; line Y 538–1288; points Y [1252, 964, 612].

- [ ] **Step 5: Чанк R10:**

```ruby
P = { node: ["Bed_D", "D.drawer3"], x0: 9368.5, x1: 9993.5, dy: 0.0,
      fb_offs: [62.5, 312.5, 562.5], fc_offs: [162.5, 462.5] }
```

- [ ] **Step 6: Сверка R10:** как R8 со сдвигом X +1370: bottom [9368.5, 188, 40, 9993.5, 938, 52]; side_L [9368.5, 188, 52, 9380.5, 938, 280]; side_R [9981.5, 188, 52, 9993.5, 938, 280]; front [9380.5, 926, 52, 9981.5, 938, 280]; back [9380.5, 188, 52, 9981.5, 200, 280]. Объёмы/cuts/pts — как R8. marks: X 9368.5 / 9993.5; закрытые Y.

- [ ] **Step 7: Ledger-запись** «Drawer Task 6: …».

### Task 7: Приёмка — счётчики, скриншоты, видимость

**Files:** нет.
**Interfaces:** Consumes — всё выше; видимость `before` из Task 1.

- [ ] **Step 1: Сводный read-only зонд.** Скрипт: счёт cpoint по 4 тегам фазы по всей модели; счёт cline/cpoint тега «Присадка»; `model.layers.size`; группы. Expected:
  - `Ø6×9 шкант пласть ящика` = **120**; `Ø6×22 шкант торец ящика` = **120**; `Ø4,5 сквозное ящика` = **204**; `Ø3 пилот ящика` = **204** (итого 648; вырезов 240 — подтверждены dV-сверками R-чанков);
  - тег «Присадка» = **40 cline + 160 cpoint** (не изменился: 20 cl + 60 cp боковин пересозданы);
  - слоёв **20**, групп **233**.
- [ ] **Step 2: Кадр 1 — общий вид.** Включить теги Ящики/Фасады ящиков/Направляющие одной операцией «MCP: приёмка — видимость (вкл)» (если были off); `get_viewport_screenshot` с камерой на выдвинутые C.drawer1/D.drawer2 (eval-камера: eye из +X+Y+Z над моделью). Проверить: дно перекрывает низ коробки (накладное), стенки на дне, фасады на местах, разметка боковин едет с выдвинутыми коробками.
- [ ] **Step 3: Кадр 2 — крупно выдвинутый D.drawer2 изнутри** (eye сверху-спереди в камеру ящика): устья шкантов на внутренних пластях боковин (3+3 на каждом углу: Z 90/130/240), точки дна по периметру, точки фасадных шурупов на пласти front.
- [ ] **Step 4: Вернуть видимость** В ТОЧНОСТИ по `before` из Task 1 одной операцией «MCP: приёмка — видимость (возврат)»; 4 новых тега фазы оставить on. Сверить зондом `list_layers` против `before`.
- [ ] **Step 5: Чек-лист приёмки:** (а) на кадрах видны вырезы и точки; (б) счётчики Step 1 сошлись; (в) видимость возвращена; (г) 233 группы, truncated=false.
- [ ] **Step 6: Ledger-запись** «Drawer Task 7: ИТОГ ФАЗЫ …» (счётчики, кадры, видимость, «модель НЕ сохранена — сохраняет пользователь»).

---

## Верификация фазы (сводно)

- 10 узлов: children = 8, узловые bbox == preflight (0.2).
- 50 новых деталей: bbox/объёмы == Expected (0.2 / ±5 мм³).
- 240 вырезов Ø6 (по dV: боковины 1509.43, front/back 3689.72 каждая).
- 648 гайд-точек: 120+120+204+204 по тегам.
- Тег «Присадка»: 40 cl + 160 cp (инвариант).
- Группы 233; слоёв 20; git не менялся; `model.save` не вызывался.

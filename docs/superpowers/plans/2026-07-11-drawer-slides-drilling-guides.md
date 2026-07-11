# Присадка направляющих SETE SB-45750 — implementation-план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** В живой модели SketchUp перестроить `A.drawer2` под боковые шариковые направляющие и нанести присадку (guide-линии + guide-точки, тег «Присадка») на все 10 ящиков четырёх кроватей по спеке `docs/superpowers/specs/2026-07-11-drawer-slides-drilling-guides-design.md`.

**Architecture:** Последовательность самодостаточных `eval_ruby`-чанков: Task 2 — одна операция перестройки, Tasks 3–6 — по одной операции присадки на кровать (данные-таблица JOBS + общий исполнительный блок). Каждый чанк возвращает JSON-отчёт; исполнитель сверяет его с Expected-таблицей таска (±0,2 мм). Финал — скриншоты с временным включением тегов.

**Tech Stack:** SketchUp MCP tools (`get_version`, `list_components`, `list_layers`, `eval_ruby`, `undo`, `get_viewport_screenshot`), SketchUp Ruby API (`Entities#add_cline/add_cpoint`, `Layers#add`), паттерны `docs/sketchup-ruby-cookbook.md`.

## Global Constraints

- Все размеры — **мм**; в Ruby только деление на 25.4 при создании точек/боксов.
- Каждый чанк сам оборачивает мутации: `model.start_operation(...)` → `commit_operation`, `abort_operation` в rescue. Один чанк = одна операция = один вызов `eval_ruby`. Операции не вкладывать.
- Чанки самодостаточны (`TOPLEVEL_BINDING.dup`): блок «Прелюдия-A» или «Прелюдия-B» вставляется целиком в начало каждого чанка вместо комментария `# --- PRELUDE-A --- / # --- PRELUDE-B ---`. Скрипты подавать без сокращений.
- Верификация: JSON-отчёт чанка сверять с Expected-таблицей таска; расхождение любой координаты > 0,2 мм = провал шага.
- Recovery: ровно один вызов MCP-инструмента `undo` (откатывает весь чанк), исправить скрипт, повторить. Не «допиливать» модель дополнительными правками.
- Чужие сущности не трогать; guides класть только в перечисленные в JOBS группы; `model.save` НЕ вызывать — сохраняет пользователь.
- Инварианты после каждого чанка: всего групп **233** (guides — не группы); bbox узлов и деталей не изменились (для Task 2 — bbox узла `A.drawer2` не изменился).
- Ledger: после каждого таска дописывать запись в `.superpowers/sdd/progress.md` (вне git).
- Общие константы разметки (миры, закрытое положение): ось Z = **160,5**; корпусная линия Y **188–938**, точки Y **901, 837, 677, 549, 261**; ящичная линия Y **188–938**, точки Y **902, 614, 262**; для выдвинутых ящиков (+350): линия Y **538–1288**, точки Y **1252, 964, 612**. Точки — от переднего торца направляющей 37/101/261/389/677 (корпусная) и 36/324/676 (ящичная), торец на Y 938 (+350 у выдвинутых боковин).
- Выдвинутые ящики: `A.drawer1`, `B.drawer2`, `C.drawer1`, `D.drawer2`. Их боковины размечаются в выдвинутых мировых координатах; рельсы и стенки — всегда в закрытых.

## Прелюдия-A (строительная — только Task 2)

Вставлять целиком вместо `# --- PRELUDE-A ---`:

```ruby
require "json"
mm = 25.4
model = Sketchup.active_model

def make_box(parent_ents, x_mm, y_mm, z_mm, w_mm, d_mm, h_mm)
  mm = 25.4
  grp = parent_ents.add_group
  face = grp.entities.add_face(
    [x_mm/mm,          y_mm/mm,          z_mm/mm],
    [(x_mm + w_mm)/mm, y_mm/mm,          z_mm/mm],
    [(x_mm + w_mm)/mm, (y_mm + d_mm)/mm, z_mm/mm],
    [x_mm/mm,          (y_mm + d_mm)/mm, z_mm/mm]
  )
  sign = face.normal.z >= 0 ? 1 : -1
  face.pushpull(sign * h_mm / mm)
  grp
end

matl = lambda do |name, r, g, b|
  m = model.materials[name] || model.materials.add(name)
  m.color = Sketchup::Color.new(r, g, b)
  m
end

part = lambda do |ents, name, material, x, y, z, w, d, h|
  g = make_box(ents, x, y, z, w, d, h)
  g.name = name
  g.material = material
  g
end

gbox = lambda do |g|
  b = g.bounds
  [b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z].map { |v| (v * mm).round(1) }
end

report = lambda do |node|
  h = {}
  node.entities.grep(Sketchup::Group).each { |g| h[g.name] = gbox.call(g) }
  h[node.name] = gbox.call(node)
  h
end
```

## Прелюдия-B (присадочная — Tasks 3–6)

Вставлять целиком вместо `# --- PRELUDE-B ---`:

```ruby
require "json"
mm = 25.4
model = Sketchup.active_model

find_child = lambda do |ents, name|
  g = ents.grep(Sketchup::Group).find { |x| x.name == name }
  raise "group not found: #{name}" unless g
  g
end

# путь ["Bed_A","A.box","A.box.wall_end_left"] → [группа, накопленный трансформ]
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

wpt = lambda { |x, y, z| Geom::Point3d.new(x / mm, y / mm, z / mm) }

# marks: [{x:, line_y: [y1,y2], z:, points_y: [...]}, ...] — все числа в МИРОВЫХ мм
mark_part = lambda do |path, marks, layer|
  part, tr = resolve.call(path)
  assert_translation.call(tr, path.join("/"))
  d = part.definition
  raise "definition shared: #{part.name}" unless d.count_instances == 1
  already = (d.entities.grep(Sketchup::ConstructionLine) +
             d.entities.grep(Sketchup::ConstructionPoint))
            .any? { |e| e.layer && e.layer.name == layer.name }
  raise "guides already present: #{part.name}" if already
  b0 = d.bounds
  w2l = tr.inverse
  out = []
  marks.each do |m|
    x = m[:x]
    y1, y2 = m[:line_y]
    z = m[:z]
    cl = d.entities.add_cline(w2l * wpt.call(x, y1, z), w2l * wpt.call(x, y2, z))
    cl.layer = layer
    pts = m[:points_y].map do |y|
      cp = d.entities.add_cpoint(w2l * wpt.call(x, y, z))
      cp.layer = layer
      cp
    end
    lw = [cl.start, cl.end].map { |p| (tr * p).to_a.map { |v| (v * mm).round(1) } }
    pw = pts.map { |cp| (tr * cp.position).to_a.map { |v| (v * mm).round(1) } }
    out << { "x" => x, "line_world" => lw, "points_world" => pw }
  end
  b1 = d.bounds
  same = (b1.min - b0.min).length < 1e-6 && (b1.max - b0.max).length < 1e-6
  raise "part bounds changed: #{part.name}" unless same
  { "part" => part.name, "marks" => out }
end

# типовые наборы меток (мировые мм, ось Z 160,5)
cab  = lambda { |x| { x: x, line_y: [188.0, 938.0],  z: 160.5, points_y: [901.0, 837.0, 677.0, 549.0, 261.0] } }
drwc = lambda { |x| { x: x, line_y: [188.0, 938.0],  z: 160.5, points_y: [902.0, 614.0, 262.0] } }
drwe = lambda { |x| { x: x, line_y: [538.0, 1288.0], z: 160.5, points_y: [1252.0, 964.0, 612.0] } }
```

## Исполнительный блок присадки (Tasks 3–6)

Вставлять целиком вместо `# --- MARK-RUN <BED> ---` (подставить имя кровати в строку операции и отчёта; `jobs` определяется таском выше блока):

```ruby
result = begin
  model.start_operation("MCP: Присадка <BED> (SETE SB-45750)", true)
  layer = model.layers.add("Присадка")
  parts_report = jobs.map { |path, marks| mark_part.call(path, marks, layer) }
  model.commit_operation
  JSON.generate({ "ok" => true, "bed" => "<BED>", "parts" => parts_report,
                  "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message,
                  "backtrace" => (e.backtrace || []).first(3) })
end
result
```

---

### Task 1: Preflight — соединение, снимок модели, готовность

**Files:** только чтение (MCP-инструменты); Append: `.superpowers/sdd/progress.md`

**Interfaces:** Produces: подтверждение «go» для Tasks 2–6 (все носители на месте, bbox совпадают).

- [ ] **Step 1: Версии.** Вызвать MCP `get_version`. Expected: `compatible: true` (python 0.3.0 ↔ ruby 0.3.0).
- [ ] **Step 2: Теги.** Вызвать MCP `list_layers`. Expected: присутствуют `Layer0, Матрасы, Ламели, Ящики, Фасады ящиков, Направляющие, Корпус`; тега `Присадка` НЕТ (если есть — стоп: присадка уже наносилась, спросить пользователя).
- [ ] **Step 3: Снимок.** Вызвать MCP `list_components` (recursive=true, max_depth=3, limit=500). Expected: `total: 233`, `truncated: false`.
- [ ] **Step 4: Сверить носителей** (±0,2 мм). Стенки, X-грани камер:

| Группа | bbox X | Грани присадки |
|---|---|---|
| `A.box.wall_end_left` | 0–18 | 18 |
| `A.box.partition_1` | 1019–1037 | 1019, 1037 |
| `A.box.wall_end_right` | 2038–2056 | 2038 |
| `B.box.wall_end_left` | 2656–2674 | 2674 |
| `B.box.partition_1` | 3335–3353 | 3335, 3353 |
| `B.box.partition_2` | 4014–4032 | 4014, 4032 |
| `B.box.wall_end_right` | 4694–4712 | 4694 |
| `C.mod1.wall_end_left` | 5312–5330 | 5330 |
| `C.mod1.wall_join_right` | 6322–6340 | 6322 |
| `C.mod2.wall_join_left` | 6340–6358 | 6358 |
| `C.mod2.wall_end_right` | 7350–7368 | 7350 |
| `D.mod1.wall_end_left` | 7968–7986 | 7986 |
| `D.mod1.wall_join_right` | 8636–8654 | 8636 |
| `D.mod2.wall_join_left` | 8654–8672 | 8672 |
| `D.mod2.wall_join_right` | 9320–9338 | 9320 |
| `D.mod3.wall_join_left` | 9338–9356 | 9356 |
| `D.mod3.wall_end_right` | 10006–10024 | 10006 |

Боковины ящиков (X-диапазон; закрытые Y 188–938, выдвинутые Y 538–1288):

| Ящик | side_L X | side_R X | Положение |
|---|---|---|---|
| A.drawer1 | 30,5–42,5 | 994,5–1006,5 | выдвинут |
| B.drawer1 | 2686,5–2698,5 | 3310,5–3322,5 | закрыт |
| B.drawer2 | 3365,5–3377,5 | 3989,5–4001,5 | выдвинут |
| B.drawer3 | 4044,5–4056,5 | 4668,5–4680,5 | закрыт |
| C.drawer1 | 5342,5–5354,5 | 6297,5–6309,5 | выдвинут |
| C.drawer2 | 6370,5–6382,5 | 7325,5–7337,5 | закрыт |
| D.drawer1 | 7998,5–8010,5 | 8611,5–8623,5 | закрыт |
| D.drawer2 | 8684,5–8696,5 | 9295,5–9307,5 | выдвинут |
| D.drawer3 | 9368,5–9380,5 | 9981,5–9993,5 | закрыт |

- [ ] **Step 5: Старый `A.drawer2`** («скрытый монтаж», подлежит перестройке): `slide_L` [1042, 188, 25 → 1082, 938, 40], `slide_R` [1993, 188, 25 → 2033, 938, 40], `side_L` [1042, 188, 40 → 1054, 938, 280], `side_R` [2021, 188, 40 → 2033, 938, 280], `front` [1054, 926, 40 → 2021, 938, 280], `back` [1054, 188, 40 → 2021, 200, 280], `bottom` [1049, 194, 53 → 2026, 930, 59], `facade` [1030, 938, 16 → 2052, 956, 286].
- [ ] **Step 6: eval-гейт.** Вызвать MCP `eval_ruby` с кодом `1 + 1`. Expected: `2`. (Если ошибка `-32010` — попросить пользователя включить Ruby evaluation в Settings.)
- [ ] **Step 7: Ledger.** Записать «Slides Task 1: complete (…)» в `.superpowers/sdd/progress.md`.

---

### Task 2: Перестройка `A.drawer2` под боковые шариковые

**Files:** живая модель — узел `A.drawer2` внутри `Bed_A`; Append: `.superpowers/sdd/progress.md`

**Interfaces:**
- Consumes: Task 1 «go»; узел `A.drawer2` с 8 детьми (Step 5 Task 1).
- Produces: новые грани боковин X **1049,5** (side_L, наружная) и **2025,5** (side_R, наружная) — их использует Task 3; рельсы на стенках камеры (Z 138–183).

- [ ] **Step 1: Вызвать `eval_ruby`** с чанком (прелюдия-A вставлена целиком):

```ruby
# --- PRELUDE-A --- (вставить целиком блок «Прелюдия-A» из этого плана)

result = begin
  bed = model.entities.grep(Sketchup::Group).find { |g| g.name == "Bed_A" }
  raise "нет Bed_A" unless bed
  node = bed.entities.grep(Sketchup::Group).find { |g| g.name == "A.drawer2" }
  raise "нет A.drawer2" unless node
  t = bed.transformation * node.transformation
  ia = t.to_a
  id_ok = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1].each_with_index.all? { |v, i| (ia[i] - v).abs < 1e-6 }
  raise "bed×node не identity" unless id_ok

  lay_box = model.layers["Ящики"]    or raise "нет тега Ящики"
  lay_sl  = model.layers["Направляющие"] or raise "нет тега Направляющие"
  ply   = matl.call("MCP Plywood", 240, 221, 176)
  metal = matl.call("MCP Metal",   158, 164, 171)

  model.start_operation("MCP: Перестройка A.drawer2 под боковые шариковые", true)

  old_names = %w[A.drawer2.slide_L A.drawer2.slide_R A.drawer2.side_L
                 A.drawer2.side_R A.drawer2.front A.drawer2.back A.drawer2.bottom]
  ne = node.entities
  old = old_names.map { |n| ne.grep(Sketchup::Group).find { |g| g.name == n } or raise "нет #{n}" }
  old.each(&:erase!)

  news = []
  news << part.call(ne, "A.drawer2.side_L", ply,   1049.5, 188.0, 40.0,   12.0, 750.0, 240.0)
  news << part.call(ne, "A.drawer2.side_R", ply,   2013.5, 188.0, 40.0,   12.0, 750.0, 240.0)
  news << part.call(ne, "A.drawer2.front",  ply,   1061.5, 926.0, 40.0,  952.0,  12.0, 240.0)
  news << part.call(ne, "A.drawer2.back",   ply,   1061.5, 188.0, 40.0,  952.0,  12.0, 240.0)
  news << part.call(ne, "A.drawer2.bottom", ply,   1056.5, 194.0, 53.0,  962.0, 736.0,   6.0)
  news << part.call(ne, "A.drawer2.slide_L", metal, 1037.0, 188.0, 138.0,  12.5, 750.0,  45.0)
  news << part.call(ne, "A.drawer2.slide_R", metal, 2025.5, 188.0, 138.0,  12.5, 750.0,  45.0)
  news.each { |g| g.layer = g.name.include?("slide") ? lay_sl : lay_box }

  model.commit_operation
  JSON.generate({ "ok" => true, "bboxes" => report.call(node) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message,
                  "backtrace" => (e.backtrace || []).first(3) })
end
result
```

- [ ] **Step 2: Сверить отчёт с Expected** (±0,2 мм):

| Группа | Expected bbox [minX, minY, minZ, maxX, maxY, maxZ] |
|---|---|
| `A.drawer2.side_L` | [1049.5, 188, 40, 1061.5, 938, 280] |
| `A.drawer2.side_R` | [2013.5, 188, 40, 2025.5, 938, 280] |
| `A.drawer2.front` | [1061.5, 926, 40, 2013.5, 938, 280] |
| `A.drawer2.back` | [1061.5, 188, 40, 2013.5, 200, 280] |
| `A.drawer2.bottom` | [1056.5, 194, 53, 2018.5, 930, 59] |
| `A.drawer2.slide_L` | [1037, 188, 138, 1049.5, 938, 183] |
| `A.drawer2.slide_R` | [2025.5, 188, 138, 2038, 938, 183] |
| `A.drawer2.facade` | [1030, 938, 16, 2052, 956, 286] (не тронут) |
| `A.drawer2` (узел) | [1030, 188, 16, 2052, 956, 286] (не изменился) |

Пересечение дно×боковины (паз 6×6, дно заходит на 5 мм в каждую боковину) — штатное, как у `A.drawer1`.

- [ ] **Step 3: При провале** — один MCP `undo`, исправить чанк, повторить Step 1.
- [ ] **Step 4: Ledger** — запись «Slides Task 2: complete (A.drawer2 → шариковые, 9 bbox точно)».

---

### Task 3: Присадка Bed_A

**Files:** живая модель — группы из JOBS ниже; Append: `.superpowers/sdd/progress.md`

**Interfaces:**
- Consumes: Task 2 (грани side_L/R **1049,5 / 2025,5**); хелперы Прелюдии-B; блок MARK-RUN.
- Produces: тег «Присадка» (создаёт `model.layers.add`, идемпотентно для Tasks 4–6); 8 линий + 32 точки в Bed_A.

- [ ] **Step 1: Вызвать `eval_ruby`** с чанком:

```ruby
# --- PRELUDE-B --- (вставить целиком блок «Прелюдия-B» из этого плана)

jobs = [
  [["Bed_A", "A.box", "A.box.wall_end_left"],  [cab.call(18.0)]],
  [["Bed_A", "A.box", "A.box.partition_1"],    [cab.call(1019.0), cab.call(1037.0)]],
  [["Bed_A", "A.box", "A.box.wall_end_right"], [cab.call(2038.0)]],
  [["Bed_A", "A.drawer1", "A.drawer1.side_L"], [drwe.call(30.5)]],
  [["Bed_A", "A.drawer1", "A.drawer1.side_R"], [drwe.call(1006.5)]],
  [["Bed_A", "A.drawer2", "A.drawer2.side_L"], [drwc.call(1049.5)]],
  [["Bed_A", "A.drawer2", "A.drawer2.side_R"], [drwc.call(2025.5)]]
]

# --- MARK-RUN Bed_A --- (вставить целиком блок «Исполнительный блок присадки», <BED> = Bed_A)
```

- [ ] **Step 2: Сверить отчёт с Expected** (±0,2 мм; во всех строках Z = 160,5):

| Деталь | X | Линия Y | Точки Y |
|---|---|---|---|
| A.box.wall_end_left | 18 | 188–938 | 901, 837, 677, 549, 261 |
| A.box.partition_1 | 1019 | 188–938 | 901, 837, 677, 549, 261 |
| A.box.partition_1 | 1037 | 188–938 | 901, 837, 677, 549, 261 |
| A.box.wall_end_right | 2038 | 188–938 | 901, 837, 677, 549, 261 |
| A.drawer1.side_L | 30,5 | 538–1288 | 1252, 964, 612 |
| A.drawer1.side_R | 1006,5 | 538–1288 | 1252, 964, 612 |
| A.drawer2.side_L | 1049,5 | 188–938 | 902, 614, 262 |
| A.drawer2.side_R | 2025,5 | 188–938 | 902, 614, 262 |

`groups_total` = 233. Итого по кровати: 8 линий, 4×5 + 4×3 = 32 точки.

- [ ] **Step 3: При провале** — один MCP `undo`, исправить, повторить.
- [ ] **Step 4: Ledger** — «Slides Task 3: complete (присадка Bed_A: 8 линий, 32 точки, тег Присадка создан)».

---

### Task 4: Присадка Bed_B

**Files:** живая модель; Append: `.superpowers/sdd/progress.md`

**Interfaces:** Consumes: Прелюдия-B, MARK-RUN, тег «Присадка» (существует после Task 3 — `layers.add` идемпотентен). Produces: 12 линий + 48 точек в Bed_B.

- [ ] **Step 1: Вызвать `eval_ruby`** с чанком:

```ruby
# --- PRELUDE-B --- (вставить целиком блок «Прелюдия-B» из этого плана)

jobs = [
  [["Bed_B", "B.box", "B.box.wall_end_left"],  [cab.call(2674.0)]],
  [["Bed_B", "B.box", "B.box.partition_1"],    [cab.call(3335.0), cab.call(3353.0)]],
  [["Bed_B", "B.box", "B.box.partition_2"],    [cab.call(4014.0), cab.call(4032.0)]],
  [["Bed_B", "B.box", "B.box.wall_end_right"], [cab.call(4694.0)]],
  [["Bed_B", "B.drawer1", "B.drawer1.side_L"], [drwc.call(2686.5)]],
  [["Bed_B", "B.drawer1", "B.drawer1.side_R"], [drwc.call(3322.5)]],
  [["Bed_B", "B.drawer2", "B.drawer2.side_L"], [drwe.call(3365.5)]],
  [["Bed_B", "B.drawer2", "B.drawer2.side_R"], [drwe.call(4001.5)]],
  [["Bed_B", "B.drawer3", "B.drawer3.side_L"], [drwc.call(4044.5)]],
  [["Bed_B", "B.drawer3", "B.drawer3.side_R"], [drwc.call(4680.5)]]
]

# --- MARK-RUN Bed_B --- (вставить целиком блок «Исполнительный блок присадки», <BED> = Bed_B)
```

- [ ] **Step 2: Сверить отчёт с Expected** (±0,2 мм; Z = 160,5):

| Деталь | X | Линия Y | Точки Y |
|---|---|---|---|
| B.box.wall_end_left | 2674 | 188–938 | 901, 837, 677, 549, 261 |
| B.box.partition_1 | 3335 | 188–938 | 901, 837, 677, 549, 261 |
| B.box.partition_1 | 3353 | 188–938 | 901, 837, 677, 549, 261 |
| B.box.partition_2 | 4014 | 188–938 | 901, 837, 677, 549, 261 |
| B.box.partition_2 | 4032 | 188–938 | 901, 837, 677, 549, 261 |
| B.box.wall_end_right | 4694 | 188–938 | 901, 837, 677, 549, 261 |
| B.drawer1.side_L | 2686,5 | 188–938 | 902, 614, 262 |
| B.drawer1.side_R | 3322,5 | 188–938 | 902, 614, 262 |
| B.drawer2.side_L | 3365,5 | 538–1288 | 1252, 964, 612 |
| B.drawer2.side_R | 4001,5 | 538–1288 | 1252, 964, 612 |
| B.drawer3.side_L | 4044,5 | 188–938 | 902, 614, 262 |
| B.drawer3.side_R | 4680,5 | 188–938 | 902, 614, 262 |

`groups_total` = 233. Итого: 12 линий, 6×5 + 6×3 = 48 точек.

- [ ] **Step 3: При провале** — один MCP `undo`, исправить, повторить.
- [ ] **Step 4: Ledger** — «Slides Task 4: complete (присадка Bed_B: 12 линий, 48 точек)».

---

### Task 5: Присадка Bed_C

**Files:** живая модель; Append: `.superpowers/sdd/progress.md`

**Interfaces:** Consumes: Прелюдия-B, MARK-RUN, тег «Присадка». Produces: 8 линий + 32 точки в Bed_C.

- [ ] **Step 1: Вызвать `eval_ruby`** с чанком:

```ruby
# --- PRELUDE-B --- (вставить целиком блок «Прелюдия-B» из этого плана)

jobs = [
  [["Bed_C", "C.mod1", "C.mod1.wall_end_left"],   [cab.call(5330.0)]],
  [["Bed_C", "C.mod1", "C.mod1.wall_join_right"], [cab.call(6322.0)]],
  [["Bed_C", "C.mod2", "C.mod2.wall_join_left"],  [cab.call(6358.0)]],
  [["Bed_C", "C.mod2", "C.mod2.wall_end_right"],  [cab.call(7350.0)]],
  [["Bed_C", "C.drawer1", "C.drawer1.side_L"],    [drwe.call(5342.5)]],
  [["Bed_C", "C.drawer1", "C.drawer1.side_R"],    [drwe.call(6309.5)]],
  [["Bed_C", "C.drawer2", "C.drawer2.side_L"],    [drwc.call(6370.5)]],
  [["Bed_C", "C.drawer2", "C.drawer2.side_R"],    [drwc.call(7337.5)]]
]

# --- MARK-RUN Bed_C --- (вставить целиком блок «Исполнительный блок присадки», <BED> = Bed_C)
```

- [ ] **Step 2: Сверить отчёт с Expected** (±0,2 мм; Z = 160,5):

| Деталь | X | Линия Y | Точки Y |
|---|---|---|---|
| C.mod1.wall_end_left | 5330 | 188–938 | 901, 837, 677, 549, 261 |
| C.mod1.wall_join_right | 6322 | 188–938 | 901, 837, 677, 549, 261 |
| C.mod2.wall_join_left | 6358 | 188–938 | 901, 837, 677, 549, 261 |
| C.mod2.wall_end_right | 7350 | 188–938 | 901, 837, 677, 549, 261 |
| C.drawer1.side_L | 5342,5 | 538–1288 | 1252, 964, 612 |
| C.drawer1.side_R | 6309,5 | 538–1288 | 1252, 964, 612 |
| C.drawer2.side_L | 6370,5 | 188–938 | 902, 614, 262 |
| C.drawer2.side_R | 7337,5 | 188–938 | 902, 614, 262 |

`groups_total` = 233. Итого: 8 линий, 32 точки.

- [ ] **Step 3: При провале** — один MCP `undo`, исправить, повторить.
- [ ] **Step 4: Ledger** — «Slides Task 5: complete (присадка Bed_C: 8 линий, 32 точки)».

---

### Task 6: Присадка Bed_D

**Files:** живая модель; Append: `.superpowers/sdd/progress.md`

**Interfaces:** Consumes: Прелюдия-B, MARK-RUN, тег «Присадка». Produces: 12 линий + 48 точек в Bed_D.

- [ ] **Step 1: Вызвать `eval_ruby`** с чанком:

```ruby
# --- PRELUDE-B --- (вставить целиком блок «Прелюдия-B» из этого плана)

jobs = [
  [["Bed_D", "D.mod1", "D.mod1.wall_end_left"],   [cab.call(7986.0)]],
  [["Bed_D", "D.mod1", "D.mod1.wall_join_right"], [cab.call(8636.0)]],
  [["Bed_D", "D.mod2", "D.mod2.wall_join_left"],  [cab.call(8672.0)]],
  [["Bed_D", "D.mod2", "D.mod2.wall_join_right"], [cab.call(9320.0)]],
  [["Bed_D", "D.mod3", "D.mod3.wall_join_left"],  [cab.call(9356.0)]],
  [["Bed_D", "D.mod3", "D.mod3.wall_end_right"],  [cab.call(10006.0)]],
  [["Bed_D", "D.drawer1", "D.drawer1.side_L"],    [drwc.call(7998.5)]],
  [["Bed_D", "D.drawer1", "D.drawer1.side_R"],    [drwc.call(8623.5)]],
  [["Bed_D", "D.drawer2", "D.drawer2.side_L"],    [drwe.call(8684.5)]],
  [["Bed_D", "D.drawer2", "D.drawer2.side_R"],    [drwe.call(9307.5)]],
  [["Bed_D", "D.drawer3", "D.drawer3.side_L"],    [drwc.call(9368.5)]],
  [["Bed_D", "D.drawer3", "D.drawer3.side_R"],    [drwc.call(9993.5)]]
]

# --- MARK-RUN Bed_D --- (вставить целиком блок «Исполнительный блок присадки», <BED> = Bed_D)
```

- [ ] **Step 2: Сверить отчёт с Expected** (±0,2 мм; Z = 160,5):

| Деталь | X | Линия Y | Точки Y |
|---|---|---|---|
| D.mod1.wall_end_left | 7986 | 188–938 | 901, 837, 677, 549, 261 |
| D.mod1.wall_join_right | 8636 | 188–938 | 901, 837, 677, 549, 261 |
| D.mod2.wall_join_left | 8672 | 188–938 | 901, 837, 677, 549, 261 |
| D.mod2.wall_join_right | 9320 | 188–938 | 901, 837, 677, 549, 261 |
| D.mod3.wall_join_left | 9356 | 188–938 | 901, 837, 677, 549, 261 |
| D.mod3.wall_end_right | 10006 | 188–938 | 901, 837, 677, 549, 261 |
| D.drawer1.side_L | 7998,5 | 188–938 | 902, 614, 262 |
| D.drawer1.side_R | 8623,5 | 188–938 | 902, 614, 262 |
| D.drawer2.side_L | 8684,5 | 538–1288 | 1252, 964, 612 |
| D.drawer2.side_R | 9307,5 | 538–1288 | 1252, 964, 612 |
| D.drawer3.side_L | 9368,5 | 188–938 | 902, 614, 262 |
| D.drawer3.side_R | 9993,5 | 188–938 | 902, 614, 262 |

`groups_total` = 233. Итого: 12 линий, 48 точек. **Общий итог по модели: 40 линий + 160 точек** (сверить суммой отчётов Tasks 3–6).

- [ ] **Step 3: При провале** — один MCP `undo`, исправить, повторить.
- [ ] **Step 4: Ledger** — «Slides Task 6: complete (присадка Bed_D: 12 линий, 48 точек; итог 40+160)».

---

### Task 7: Скриншоты и визуальная приёмка

**Files:** живая модель (только видимость тегов + rendering option, всё возвращается); Append: `.superpowers/sdd/progress.md`

**Interfaces:** Consumes: Tasks 2–6 выполнены. Produces: 2 кадра, чек-лист приёмки, финальная ledger-запись.

- [ ] **Step 1: Включить теги для кадра 1** — `eval_ruby` (операция):

```ruby
require "json"
model = Sketchup.active_model
result = begin
  names = ["Матрасы", "Ламели", "Ящики", "Фасады ящиков", "Направляющие", "Корпус", "Присадка"]
  before = {}
  ro_before = model.rendering_options["HideConstructionGeometry"]
  model.start_operation("MCP: теги для приёмки присадки (кадр 1)", true)
  names.each { |n| l = model.layers[n]; raise "нет тега #{n}" unless l; before[n] = l.visible? }
  ["Ящики", "Фасады ящиков", "Направляющие", "Присадка"].each { |n| model.layers[n].visible = true }
  model.commit_operation
  model.rendering_options["HideConstructionGeometry"] = false
  JSON.generate({ "ok" => true, "before" => before, "hide_guides_before" => ro_before })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message })
end
result
```

Сохранить `before` и `hide_guides_before` из отчёта — они нужны в Step 6.

- [ ] **Step 2: Камера на всю сцену** — `eval_ruby` (камера — не мутация, операция не нужна):

```ruby
model = Sketchup.active_model
b = Geom::BoundingBox.new
model.entities.grep(Sketchup::Group).each { |g| b.add(g.bounds) }
dir = Geom::Vector3d.new(1, 1.1, 0.75).normalize
eye = b.center.offset(dir, b.diagonal * 1.25)
model.active_view.camera = Sketchup::Camera.new(eye, b.center, Geom::Vector3d.new(0, 0, 1))
"camera scene"
```

Затем MCP `get_viewport_screenshot`. Expected: 4 кровати, у всех ящиков видны фасады; присадка включена.

- [ ] **Step 3: Кадр 2 — корпус Bed_A без ящиков** — `eval_ruby` (операция):

```ruby
require "json"
model = Sketchup.active_model
result = begin
  model.start_operation("MCP: теги для приёмки присадки (кадр 2)", true)
  ["Ящики", "Фасады ящиков", "Направляющие", "Матрасы", "Ламели"].each do |n|
    l = model.layers[n]; raise "нет тега #{n}" unless l
    l.visible = false
  end
  model.commit_operation
  JSON.generate({ "ok" => true })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message })
end
result
```

- [ ] **Step 4: Камера на Bed_A** — `eval_ruby`:

```ruby
model = Sketchup.active_model
bed = model.entities.grep(Sketchup::Group).find { |g| g.name == "Bed_A" }
b = bed.bounds
dir = Geom::Vector3d.new(1, 1.1, 0.75).normalize
eye = b.center.offset(dir, b.diagonal * 1.1)
model.active_view.camera = Sketchup::Camera.new(eye, b.center, Geom::Vector3d.new(0, 0, 1))
"camera Bed_A"
```

Затем MCP `get_viewport_screenshot`. Expected: голый корпус A, на стенках камер видны пунктирные осевые линии с точками (Z ≈ 160), стяжки/царга на месте.

- [ ] **Step 5: Чек-лист приёмки:** (а) линии на обеих стенках каждой камеры; (б) на кадре 1 у выдвинутых ящиков разметка на боковинах едет вместе с коробкой; (в) `A.drawer2` больше не «скрытый монтаж»: рельсов под дном нет, рельсы на стенках.
- [ ] **Step 6: Вернуть видимость точно** — `eval_ruby` (операция; подставить значения `before` из Step 1, `Присадка` остаётся true):

```ruby
require "json"
model = Sketchup.active_model
result = begin
  before = {
    "Матрасы" => false, "Ламели" => false, "Ящики" => false,
    "Фасады ящиков" => false, "Направляющие" => true, "Корпус" => true
  } # ← ЗАМЕНИТЬ на фактические значения из отчёта Step 1
  model.start_operation("MCP: возврат видимости после приёмки", true)
  before.each { |n, v| model.layers[n].visible = v }
  model.layers["Присадка"].visible = true
  model.commit_operation
  model.rendering_options["HideConstructionGeometry"] = false # ← значение hide_guides_before из Step 1
  JSON.generate({ "ok" => true })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message })
end
result
```

- [ ] **Step 7: Ledger** — финальная запись: перестройка + присадка завершены, счётчики (233 группы; 40 линий + 160 точек; тег Присадка видим), напоминание пользователю сохранить модель самому.

---

## Примечание для исполнителя

- Порядок: Task 2 обязан идти до Task 3 (грани 1049,5/2025,5 существуют только после перестройки). Tasks 4–6 геометрически независимы, но выполнять по порядку — проще откатывать хвост.
- Линии корпусной части лежат в плоскости контакта рельс↔стенка: при включённом теге «Направляющие» они частично закрыты телами рельсов — это ожидаемо (кадр 2 снимается без «Направляющих»).
- Каждый вызов `eval_ruby` проходит per-call review в MCP-клиенте — не объединять чанки.
- Координаты в чанках мировые; `mark_part` сам переводит их в локальные координаты детали через обратный трансформ и проверяет, что трансформ — чистая трансляция.
- Точки присадки — типовые (GTV H45 GX); перед реальным сверлением пользователь сверяет их с купленными SETE (дисклеймер спеки §4.1).

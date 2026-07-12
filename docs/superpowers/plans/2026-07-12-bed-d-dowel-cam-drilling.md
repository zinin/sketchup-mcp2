# Присадка Bed_D (шканты 8 + минификсы) — implementation-план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** В живой модели SketchUp высверлить в деталях Bed_D отверстия под шканты Ø8, минификсы 15/B34 и межсекционные стяжки, и нанести guide-точки (устья всех отверстий + шурупные места) на 8 тегах в папке «Присадка D» — по спеке `docs/superpowers/specs/2026-07-12-bed-d-dowel-cam-drilling-design.md`.

**Architecture:** Последовательность самодостаточных `eval_ruby`-чанков: C0 — теги; C1–C3 — вырезы+точки по модулям (data-driven: общая Прелюдия-C, генератор jobs, меняется одна строка `MOD_INDEX`); C4 — межсекционные стыки; C5 — шурупные точки; C6 — скриншоты-приёмка. Каждый вырез = окружность 24 сегмента на грани + `pushpull` внутрь `definition.entities` (solid-tools запрещены — пересоздают группу и убьют guide-точки присадки направляющих). Каждый чанк возвращает JSON-отчёт; исполнитель сверяет с Expected таска.

**Tech Stack:** SketchUp MCP (`get_version`, `list_components`, `eval_ruby`, `undo`, `get_viewport_screenshot`), SketchUp Ruby API (`Entities#add_circle/add_cpoint`, `Face#pushpull`, `Layers#add_folder`), рецепты `docs/sketchup-ruby-cookbook.md`.

## Global Constraints

- Все размеры — **мм**, мировые координаты; в Ruby деление на 25.4 только в хелперах.
- Один чанк = одна операция `model.start_operation` → `commit_operation`, `abort_operation` в rescue; операции не вкладывать; `puts` не виден — чанк заканчивается JSON-строкой.
- Чанки самодостаточны: блок «Прелюдия-C» вставляется целиком вместо `# --- PRELUDE-C ---`. Скрипты подавать без сокращений.
- Перед мутацией каждая деталь проходит assert: накопленный трансформ — чистая трансляция (±1e-6), definition не shared.
- Допуски: позиции/bbox **±0,2 мм**; объёмные дельты **±5 мм³** на деталь (площадь 24-угольника: `½·24·r²·sin 15°` — формула точная).
- Канал под шток минификса: в модели глубина **26 мм** (перемычка 0,5 мм до стакана — касание граней даёт мусор), реальное сверление **36 мм** — закодировано в имени тега «Ø8×36 канал».
- Инварианты после каждого чанка: групп **233**; bbox деталей/узлов не изменились; в каждой стенке ровно **6** guide-сущностей присадки направляющих (1 cline + 5 cpoint) + новые cpoint этого чанка; чужие сущности не тронуты.
- Провал → ровно один MCP `undo` → исправить чанк → повторить. `model.save` НЕ вызывать — сохраняет пользователь.
- Ledger: после каждого таска дописывать `.superpowers/sdd/progress.md` (вне git; запись «Cam Task N»).
- **Матрица коллизий рассчитана при написании плана** (см. ниже). При ЛЮБОМ изменении координат — пересчитать вручную минимальные разносы; менять позиции без пересчёта запрещено.
- Существующие 8 тегов модели не трогать; видимость после C6 вернуть в точности (before снимается в Task 1).

## Матрица коллизий (рассчитано; данные плана ей соответствуют)

- Канал Ø8×26 от торца (устье Y=18 / X=торец) заканчивается за 0,5 мм до стакана (ось стакана — 34 мм от торца, ближний край полости 26,5).
- Γ-стенки 18 мм, встречные глухие вырезы: стаканы J1 (Y 52; Z 50/310, камерная сторона) vs шканты J4 (Y 120/850; Z 60/300, стыковая) — мин. разнос осей в плоскости пласти ≈ 68,7 мм; ответные J3 (Z 9) vs J4 (Z 60) ≈ 52; язычковый шкант J4 (Y 929, Z 150) vs штоки/ответные J2 (Y 929, Z 315–395) ≥ 165. Всюду ≥ 40 или встречная пара не глубже 13+13 с перемычкой ≥ 5.
- Присадка направляющих (камерные грани, ось Z 160,5, линия Y 188–938): ближайший вырез на тех же гранях — Ø7 на Z 260 (зазор 99,5) и Z 100 (60,5); язычковый шкант J4 (Z 150, dZ 10,5) лежит на **стыковой** грани, глубина 13, до камерной грани остаётся 5 мм — на камерную разметку не выходит.
- Шурупные оси: J5-центр mod2 смещён с центра камеры (X 8996) на **X 9046** — иначе лобовое пересечение с пилотом ламели slat_07 (X 8996, встреча в точке Y 41, Z 340). Мин. скрещивающийся разнос J5↔J6 после смещения: 10 мм (mod1/mod3 края, Ø3 против Ø3 — 7 мм массива между осями, приемлемо).
- Пилоты царги J5 (Y 920, Z 340) vs стаканы царги J2 (Y 920, Z 355): разнос √(46²+15²) ≈ 48,4 мм.

## Прелюдия-C (вставлять целиком вместо `# --- PRELUDE-C ---`)

```ruby
require "json"
MM = 25.4
model = Sketchup.active_model

T_CUP   = "Ø15×13 стакан"
T_CH    = "Ø8×36 канал"
T_DT    = "Ø8×25 шкант торец"
T_DF    = "Ø8×13 шкант пласть"
T_PIN   = "Ø5×11,5 шток"
T_BOLT  = "Ø7 сквозное"
T_SCR   = "Ø4,5 шуруп скв"
T_PILOT = "Ø3 пилот"
TAG_NAMES = [T_CUP, T_CH, T_DT, T_DF, T_PIN, T_BOLT, T_SCR, T_PILOT]

find_child = lambda do |ents, name|
  g = ents.grep(Sketchup::Group).find { |x| x.name == name }
  raise "group not found: #{name}" unless g
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
AX = { x: Geom::Vector3d.new(1, 0, 0), y: Geom::Vector3d.new(0, 1, 0), z: Geom::Vector3d.new(0, 0, 1) }
poly_area = lambda { |dia| 0.5 * 24 * (dia / 2.0)**2 * Math.sin(2 * Math::PI / 24) } # мм²

tags = {}
load_tags = lambda do
  TAG_NAMES.each do |nm|
    l = model.layers[nm]
    raise "tag missing (run chunk C0 first): #{nm}" unless l
    tags[nm] = l
  end
end

parts_cache = {}
get_part = lambda do |path|
  key = path.join("/")
  parts_cache[key] ||= begin
    part, tr = resolve.call(path)
    assert_translation.call(tr, key)
    d = part.definition
    raise "definition shared: #{key}" unless d.count_instances == 1
    v0 = part.volume
    raise "not a solid before cuts: #{key}" unless v0.is_a?(Numeric) && v0 > 0
    { part: part, tr: tr, inv: tr.inverse, d: d, vol0: v0, b0: d.bounds,
      g0: d.entities.grep(Sketchup::ConstructionLine).size +
          d.entities.grep(Sketchup::ConstructionPoint).size,
      delta_exp: 0.0, cuts: 0, pts: 0 }
  end
end

# job = { part:[путь], ax: :x|:y|:z, s: +1|-1 (НАРУЖНАЯ нормаль грани устья),
#         c:[x,y,z мир мм], dia:, depth:, tag:, thru: true|nil }
J = lambda do |part, ax, s, x, y, z, dia, depth, tag, thru = nil|
  { part: part, ax: ax, s: s, c: [x.to_f, y.to_f, z.to_f],
    dia: dia.to_f, depth: depth.to_f, tag: tag, thru: thru }
end

drill = lambda do |job|
  rec = get_part.call(job[:part])
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
  if job[:thru]
    raise "thru-hole left a floor @#{job[:c]}" if face.valid?
  else
    raise "blind hole lost its floor @#{job[:c]}" unless face.valid?
    depth_fact = ((face.vertices.first.position - cl) % n).abs * MM
    raise "depth #{depth_fact.round(2)} != #{job[:depth]} @#{job[:c]}" if (depth_fact - job[:depth]).abs > 0.2
  end
  cp = d.entities.add_cpoint(cl)
  cp.layer = tags[job[:tag]]
  rec[:delta_exp] += poly_area.call(job[:dia]) * job[:depth]
  rec[:cuts] += 1
  rec[:pts] += 1
end

point_only = lambda do |path, x, y, z, tag|
  rec = get_part.call(path)
  cp = rec[:d].entities.add_cpoint(rec[:inv] * wpt.call(x, y, z))
  cp.layer = tags[tag]
  rec[:pts] += 1
end

finalize = lambda do
  parts_cache.map do |key, rec|
    v1 = rec[:part].volume
    raise "not a solid after cuts: #{key}" unless v1.is_a?(Numeric) && v1 > 0
    delta_fact = (rec[:vol0] - v1) * MM**3
    raise "volume mismatch #{key}: fact #{delta_fact.round(2)} exp #{rec[:delta_exp].round(2)}" if (delta_fact - rec[:delta_exp]).abs > 5.0
    b1 = rec[:d].bounds
    bb_ok = (b1.min - rec[:b0].min).length * MM < 0.2 && (b1.max - rec[:b0].max).length * MM < 0.2
    raise "bbox changed: #{key}" unless bb_ok
    g1 = rec[:d].entities.grep(Sketchup::ConstructionLine).size +
         rec[:d].entities.grep(Sketchup::ConstructionPoint).size
    raise "guides count broken: #{key} was #{rec[:g0]}, new #{rec[:pts]}, now #{g1}" unless g1 == rec[:g0] + rec[:pts]
    { "part" => key.split("/").last, "cuts" => rec[:cuts], "points" => rec[:pts],
      "dV_exp" => rec[:delta_exp].round(1), "dV_fact" => delta_fact.round(1) }
  end
end

# --- данные Bed_D (мировые мм; сняты зондом 2026-07-12, отклонение 0.0) ---
MODS = [
  { node: "D.mod1", wb: "D.mod1.wall_back", ca: 7986.0, cb: 8636.0,
    rail: "D.mod1.rail_front", sf: "D.mod1.stretcher_front", sm: "D.mod1.stretcher_mid",
    walls: [{ name: "D.mod1.wall_end_left",   x0: 7968.0,  x1: 7986.0,  cav: +1, h: 420.0 },
            { name: "D.mod1.wall_join_right", x0: 8636.0,  x1: 8654.0,  cav: -1, h: 360.0 }] },
  { node: "D.mod2", wb: "D.mod2.wall_back", ca: 8672.0, cb: 9320.0,
    rail: "D.mod2.rail_front", sf: "D.mod2.stretcher_front", sm: "D.mod2.stretcher_mid",
    walls: [{ name: "D.mod2.wall_join_left",  x0: 8654.0,  x1: 8672.0,  cav: +1, h: 360.0 },
            { name: "D.mod2.wall_join_right", x0: 9320.0,  x1: 9338.0,  cav: -1, h: 360.0 }] },
  { node: "D.mod3", wb: "D.mod3.wall_back", ca: 9356.0, cb: 10006.0,
    rail: "D.mod3.rail_front", sf: "D.mod3.stretcher_front", sm: "D.mod3.stretcher_mid",
    walls: [{ name: "D.mod3.wall_join_left",  x0: 9338.0,  x1: 9356.0,  cav: +1, h: 360.0 },
            { name: "D.mod3.wall_end_right",  x0: 10006.0, x1: 10024.0, cav: -1, h: 420.0 }] }
]

# J1+J2+J3 одного модуля → 62 job
build_module_jobs = lambda do |mi|
  jobs = []
  bed = "Bed_D"
  wbp = [bed, mi[:node], mi[:wb]]
  ca = mi[:ca]
  cb = mi[:cb]
  mi[:walls].each do |w|
    wp = [bed, mi[:node], w[:name]]
    xm = (w[:x0] + w[:x1]) / 2.0
    xc = w[:cav] > 0 ? w[:x1] : w[:x0]
    zc = w[:h] == 420.0 ? [50.0, 370.0] : [50.0, 310.0]
    zd = w[:h] == 420.0 ? [155.0, 265.0] : [130.0, 230.0]
    zc.each do |z|
      jobs << J.call(wp,  :x, w[:cav], xc, 52.0, z, 15.0, 13.0, T_CUP)
      jobs << J.call(wp,  :y, -1, xm, 18.0, z, 8.0, 26.0, T_CH)
      jobs << J.call(wbp, :y, +1, xm, 18.0, z, 5.0, 11.5, T_PIN)
    end
    zd.each do |z|
      jobs << J.call(wp,  :y, -1, xm, 18.0, z, 8.0, 25.0, T_DT)
      jobs << J.call(wbp, :y, +1, xm, 18.0, z, 8.0, 13.0, T_DF)
    end
  end
  beams = [[mi[:rail], 929.0, 315.0, 395.0, 355.0, :rail],
           [mi[:sf],   863.0, 813.0, 913.0, 9.0,   :str],
           [mi[:sm],   475.0, 425.0, 525.0, 9.0,   :str]]
  lw, rw = mi[:walls]
  beams.each do |bname, yc, yd1, yd2, zc2, kind|
    bp = [bed, mi[:node], bname]
    [[ca, -1, lw], [cb, +1, rw]].each do |xt, s, w|
      wp = [bed, mi[:node], w[:name]]
      xcup = xt - s * 34.0
      jobs << J.call(bp, :x, s, xt, yc, zc2, 8.0, 26.0, T_CH)
      jobs << (kind == :rail ?
        J.call(bp, :y, -1, xcup, 920.0, zc2, 15.0, 13.0, T_CUP) :
        J.call(bp, :z, +1, xcup, yc, 18.0, 15.0, 13.0, T_CUP))
      [yd1, yd2].each do |yd|
        jobs << J.call(bp, :x, s,  xt, yd, zc2, 8.0, 25.0, T_DT)
        jobs << J.call(wp, :x, -s, xt, yd, zc2, 8.0, 13.0, T_DF)
      end
      jobs << J.call(wp, :x, -s, xt, yc, zc2, 5.0, 11.5, T_PIN)
    end
  end
  jobs
end
```

## Исполнительный блок вырезов (чанки C1–C3)

Вставлять целиком вместо `# --- CUT-RUN ---` (перед ним таск задаёт `MOD_INDEX`):

```ruby
mi = MODS[MOD_INDEX]
jobs = build_module_jobs.call(mi)
raise "jobs sanity: #{jobs.size}" unless jobs.size == 62
result = begin
  model.start_operation("MCP: Присадка D — вырезы #{mi[:node]}", true)
  load_tags.call
  jobs.each { |j| drill.call(j) }
  parts = finalize.call
  model.commit_operation
  JSON.generate({ "ok" => true, "chunk" => mi[:node], "jobs" => jobs.size,
                  "tag_counts" => jobs.group_by { |j| j[:tag] }.map { |t, a| [t, a.size] }.to_h,
                  "parts" => parts, "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message, "backtrace" => (e.backtrace || []).first(3) })
end
result
```

---

### Task 1: Preflight — соединение, снимок модели, готовность

**Files:** только чтение (MCP); Append: `.superpowers/sdd/progress.md`

**Interfaces:** Produces: «go» для Tasks 2–8 (носители на месте, присадки D ещё нет).

- [ ] **Step 1: Версии.** MCP `get_version`. Expected: `compatible: true` (python 0.3.0 ↔ ruby 0.3.0).
- [ ] **Step 2: Снимок.** MCP `list_components` (recursive=true, max_depth=3, limit=500). Expected: `total: 233`, `truncated: false`; присутствуют все группы `D.mod1..3` из MODS, `D.slats.slat_01..13`, бруски `D.mod*.cleat_back/front`.
- [ ] **Step 3: Зонд Bed_D** (read-only `eval_ruby`, без операции):

```ruby
# --- PRELUDE-C --- (вставить целиком; save/операций зонд не делает)
probe = {}
(MODS + [{ node: "D.slats" }]).each do |mi|
  node = find_child.call(find_child.call(model.entities, "Bed_D").entities, mi[:node])
  node.entities.grep(Sketchup::Group).each do |part|
    _, tr = resolve.call(["Bed_D", mi[:node], part.name])
    assert_translation.call(tr, part.name)
    d = part.definition
    wmin = tr * d.bounds.min
    wmax = tr * d.bounds.max
    probe[part.name] = {
      "w" => [wmin.x, wmin.y, wmin.z, wmax.x, wmax.y, wmax.z].map { |v| (v * MM).round(2) },
      "vol" => (part.volume * MM**3).round(1),
      "guides" => d.entities.grep(Sketchup::ConstructionLine).size +
                  d.entities.grep(Sketchup::ConstructionPoint).size }
  end
end
probe["tags"] = model.layers.map(&:name).sort
probe["folders"] = model.layers.folders.map(&:name)
JSON.generate(probe)
```

- [ ] **Step 4: Сверить зонд с Expected** (±0,2 мм; объёмы точно):

| Группа | bbox мир [Xmin,Ymin,Zmin → Xmax,Ymax,Zmax] | vol, мм³ | guides |
|---|---|---|---|
| D.mod1.wall_back | 7968,0,0 → 8654,18,420 | 5 186 160 | 0 |
| D.mod1.wall_end_left | 7968,18,0 → 7986,938,420 | 6 955 200 | 6 |
| D.mod1.wall_join_right | 8636,18,0 → 8654,938,420 | 5 981 040 | 6 |
| D.mod1.rail_front | 7986,920,290 → 8636,938,420 | 1 521 000 | 0 |
| D.mod1.cleat_back | 7986,18,320 → 8636,58,360 | 1 040 000 | 0 |
| D.mod1.cleat_front | 7986,880,320 → 8636,920,360 | 1 040 000 | 0 |
| D.mod1.stretcher_front | 7986,788,0 → 8636,938,18 | 1 755 000 | 0 |
| D.mod1.stretcher_mid | 7986,400,0 → 8636,550,18 | 1 755 000 | 0 |
| D.mod2.wall_back | 8654,0,0 → 9338,18,420 | 5 171 040 | 0 |
| D.mod2.wall_join_left | 8654,18,0 → 8672,938,420 | 5 981 040 | 6 |
| D.mod2.wall_join_right | 9320,18,0 → 9338,938,420 | 5 981 040 | 6 |
| D.mod2.rail_front | 8672,920,290 → 9320,938,420 | 1 516 320 | 0 |
| D.mod2.cleat_back / cleat_front | 8672,18|880,320 → 9320,58|920,360 | 1 036 800 | 0 |
| D.mod2.stretcher_front / mid | 8672,788|400,0 → 9320,938|550,18 | 1 749 600 | 0 |
| D.mod3.wall_back | 9338,0,0 → 10024,18,420 | 5 186 160 | 0 |
| D.mod3.wall_join_left | 9338,18,0 → 9356,938,420 | 5 981 040 | 6 |
| D.mod3.wall_end_right | 10006,18,0 → 10024,938,420 | 6 955 200 | 6 |
| D.mod3.rail_front | 9356,920,290 → 10006,938,420 | 1 521 000 | 0 |
| D.mod3.cleat_back / cleat_front | 9356,18|880,320 → 10006,58|920,360 | 1 040 000 | 0 |
| D.mod3.stretcher_front / mid | 9356,788|400,0 → 10006,938|550,18 | 1 755 000 | 0 |
| D.slats.slat_01..13 | старты X 8011, 8167.7, 8324.3, 8481, 8637.7, 8794.3, 8951, 9107.7, 9264.3, 9421, 9577.7, 9734.3, 9891 (+90); Y 24–914, Z 360–380 | 1 602 000 | 0 |
| tags | ровно 8: Layer0, Корпус, Ламели, Матрасы, Направляющие, Присадка, Фасады ящиков, Ящики | | |
| folders | `[]` — папок нет | | |

Любое расхождение → СТОП, вопрос пользователю (модель разошлась с ledger).
- [ ] **Step 5: Видимость before.** MCP `list_layers` — записать видимость всех тегов (ожидание: Layer0/Направляющие/Корпус/Присадка on; Матрасы/Ламели/Ящики/Фасады ящиков off). Понадобится для точного возврата в Task 8.
- [ ] **Step 6: Ledger.** Append: `Cam Task 1: complete (preflight: версии ok, 233 группы, зонд Bed_D — все bbox/объёмы/guides точно, тегов 8, папок нет, видимость before зафиксирована)`.

### Task 2: Чанк C0 — папка тегов «Присадка D»

**Files:** мутация модели (`eval_ruby`); Append: ledger

**Interfaces:** Consumes: Task 1 «go». Produces: 8 тегов TAG_NAMES в папке «Присадка D» — их требует `load_tags` чанков C1–C5.

- [ ] **Step 1: Запустить чанк C0** (`eval_ruby`, целиком):

```ruby
# --- PRELUDE-C ---
result = begin
  model.start_operation("MCP: Присадка D — теги", true)
  raise "folder exists" if model.layers.folders.any? { |f| f.name == "Присадка D" }
  TAG_NAMES.each { |nm| raise "tag exists: #{nm}" if model.layers[nm] }
  folder = model.layers.add_folder("Присадка D")
  TAG_NAMES.each { |nm| folder.add_layer(model.layers.add(nm)) }
  model.commit_operation
  JSON.generate({ "ok" => true, "folder" => folder.name,
                  "in_folder" => folder.layers.map(&:name).sort,
                  "layers_total" => model.layers.size,
                  "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message, "backtrace" => (e.backtrace || []).first(3) })
end
result
```

- [ ] **Step 2: Сверить отчёт.** Expected: `ok:true`; `in_folder` — все 8 имён TAG_NAMES (отсортированы); `layers_total: 16` (8 старых + 8 новых); `groups_total: 233`.
- [ ] **Step 3: Ledger.** Append: `Cam Task 2: complete (папка «Присадка D» + 8 тегов, слоёв 16, групп 233)`.

### Task 3: Чанк C1 — вырезы и точки D.mod1

**Files:** мутация модели; Append: ledger

**Interfaces:** Consumes: теги из Task 2. Produces: 62 выреза + 62 точки в 6 деталях mod1.

- [ ] **Step 1: Запустить чанк C1** (`eval_ruby`, целиком):

```ruby
# --- PRELUDE-C ---
MOD_INDEX = 0
# --- CUT-RUN ---
```

- [ ] **Step 2: Сверить отчёт с Expected:**

`ok:true`, `jobs:62`, `groups_total:233`;
`tag_counts`: {Ø15×13 стакан: 10, Ø8×36 канал: 10, Ø8×25 шкант торец: 16, Ø8×13 шкант пласть: 16, Ø5×11,5 шток: 10};
`parts` (dV_exp = dV_fact ± 5 мм³):

| part | cuts | points | dV_exp, мм³ |
|---|---|---|---|
| D.mod1.wall_back | 8 | 8 | 3477.0 |
| D.mod1.wall_end_left | 15 | 15 | 14156.8 |
| D.mod1.wall_join_right | 15 | 15 | 14156.8 |
| D.mod1.rail_front | 8 | 8 | 12095.6 |
| D.mod1.stretcher_front | 8 | 8 | 12095.6 |
| D.mod1.stretcher_mid | 8 | 8 | 12095.6 |

(Проверки позиций, глубин, solid, bbox, целостности старых guides выполняет сам чанк — `drill`/`finalize` бросают исключение и всё откатывается.)
- [ ] **Step 3: При провале** — ответ `ok:false` означает, что операция откатилась сама (abort в rescue); если `ok:true`, но Expected разошёлся — ровно один MCP `undo`, исправить чанк, повторить.
- [ ] **Step 4: Ledger.** Append: `Cam Task 3: complete (mod1: 62 выреза + 62 точки, дельты объёмов точно, 233 группы)` + фактические цифры.

### Task 4: Чанк C2 — вырезы и точки D.mod2

**Files:** мутация модели; Append: ledger

**Interfaces:** Consumes: теги. Produces: 62 выреза + 62 точки в 6 деталях mod2.

- [ ] **Step 1: Запустить чанк C2** — код Task 3 Step 1 дословно, кроме одной строки: `MOD_INDEX = 1`.
- [ ] **Step 2: Сверить отчёт.** Expected как в Task 3 c именами mod2: wall_back 8/3477.0; wall_join_left 15/14156.8; wall_join_right 15/14156.8; rail_front 8/12095.6; stretcher_front 8/12095.6; stretcher_mid 8/12095.6; tag_counts те же; групп 233.
- [ ] **Step 3: Ledger.** Append: `Cam Task 4: complete (mod2: 62+62, 233)` + цифры.

### Task 5: Чанк C3 — вырезы и точки D.mod3

**Files:** мутация модели; Append: ledger

**Interfaces:** Consumes: теги. Produces: 62 выреза + 62 точки в 6 деталях mod3.

- [ ] **Step 1: Запустить чанк C3** — код Task 3 Step 1 дословно, кроме: `MOD_INDEX = 2`.
- [ ] **Step 2: Сверить отчёт.** Expected как в Task 3 с именами mod3: wall_back 8/3477.0; wall_join_left 15/14156.8; wall_end_right 15/14156.8; rail_front 8/12095.6; stretcher_front 8/12095.6; stretcher_mid 8/12095.6; групп 233.
- [ ] **Step 3: Ledger.** Append: `Cam Task 5: complete (mod3: 62+62, 233)` + цифры.

### Task 6: Чанк C4 — межсекционные стыки Γ↔Γ

**Files:** мутация модели; Append: ledger

**Interfaces:** Consumes: теги; Γ-стенки уже несут вырезы C1–C3. Produces: 36 вырезов + 36 точек в 4 Γ-стенках.

- [ ] **Step 1: Запустить чанк C4** (`eval_ruby`, целиком):

```ruby
# --- PRELUDE-C ---
SEAMS = [
  { xs: 8654.0, lg: ["D.mod1", "D.mod1.wall_join_right"], rg: ["D.mod2", "D.mod2.wall_join_left"] },
  { xs: 9338.0, lg: ["D.mod2", "D.mod2.wall_join_right"], rg: ["D.mod3", "D.mod3.wall_join_left"] }
]
DOWELS = [[120.0, 60.0], [120.0, 300.0], [850.0, 60.0], [850.0, 300.0], [929.0, 150.0]]
BOLTS  = [[300.0, 100.0], [300.0, 260.0], [650.0, 100.0], [650.0, 260.0]]
jobs = []
SEAMS.each do |sm|
  lp = ["Bed_D", *sm[:lg]]
  rp = ["Bed_D", *sm[:rg]]
  DOWELS.each do |y, z|
    jobs << J.call(lp, :x, +1, sm[:xs], y, z, 8.0, 13.0, T_DF)
    jobs << J.call(rp, :x, -1, sm[:xs], y, z, 8.0, 13.0, T_DF)
  end
  BOLTS.each do |y, z|
    jobs << J.call(lp, :x, -1, sm[:xs] - 18.0, y, z, 7.0, 18.0, T_BOLT, true)
    jobs << J.call(rp, :x, +1, sm[:xs] + 18.0, y, z, 7.0, 18.0, T_BOLT, true)
  end
end
raise "jobs sanity: #{jobs.size}" unless jobs.size == 36
result = begin
  model.start_operation("MCP: Присадка D — межсекционные стыки", true)
  load_tags.call
  jobs.each { |j| drill.call(j) }
  parts = finalize.call
  model.commit_operation
  JSON.generate({ "ok" => true, "chunk" => "seams", "jobs" => jobs.size,
                  "tag_counts" => jobs.group_by { |j| j[:tag] }.map { |t, a| [t, a.size] }.to_h,
                  "parts" => parts, "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message, "backtrace" => (e.backtrace || []).first(3) })
end
result
```

- [ ] **Step 2: Сверить отчёт.** Expected: `ok:true`, `jobs:36`, `groups_total:233`; `tag_counts`: {Ø8×13 шкант пласть: 20, Ø7 сквозное: 16}; `parts` — 4 Γ-стенки (wall_join_right×2, wall_join_left×2), у каждой cuts 9, points 9, dV_exp **5969.4** (5 шкантов 646.0 + 4 сквозных 684.8).
  Guides-инвариант чанк проверяет сам: в Γ теперь 6 старых + 15 точек C1–C3 + 9 новых.
- [ ] **Step 3: Ledger.** Append: `Cam Task 6: complete (межсекционные: 2 стыка, 36 вырезов+точек, dV 5969.4×4, 233)`.

### Task 7: Чанк C5 — шурупные guide-точки (бруски, ламели)

**Files:** мутация модели; Append: ledger

**Interfaces:** Consumes: теги. Produces: 88 cpoint (без вырезов) в wall_back×3, cleat×6, rail×3, slat×13.

- [ ] **Step 1: Запустить чанк C5** (`eval_ruby`, целиком):

```ruby
# --- PRELUDE-C ---
SCREW_X = { "D.mod1" => [8066.0, 8311.0, 8556.0],
            "D.mod2" => [8752.0, 9046.0, 9240.0],   # центр смещён: коллизия со slat_07 (X 8996)
            "D.mod3" => [9436.0, 9681.0, 9926.0] }
SLATS = [["D.slats.slat_01", 8056.0,  "D.mod1"], ["D.slats.slat_02", 8212.7,  "D.mod1"],
         ["D.slats.slat_03", 8369.3,  "D.mod1"], ["D.slats.slat_04", 8526.0,  "D.mod1"],
         ["D.slats.slat_05", 8699.85, "D.mod2"], ["D.slats.slat_06", 8839.3,  "D.mod2"],
         ["D.slats.slat_07", 8996.0,  "D.mod2"], ["D.slats.slat_08", 9152.7,  "D.mod2"],
         ["D.slats.slat_09", 9292.15, "D.mod2"], ["D.slats.slat_10", 9466.0,  "D.mod3"],
         ["D.slats.slat_11", 9622.7,  "D.mod3"], ["D.slats.slat_12", 9779.3,  "D.mod3"],
         ["D.slats.slat_13", 9936.0,  "D.mod3"]]
result = begin
  model.start_operation("MCP: Присадка D — шурупные точки", true)
  load_tags.call
  n = 0
  SCREW_X.each do |mod, xs|
    xs.each do |x|
      point_only.call(["Bed_D", mod, "#{mod}.wall_back"],   x, 0.0,   340.0, T_SCR)
      point_only.call(["Bed_D", mod, "#{mod}.cleat_back"],  x, 18.0,  340.0, T_PILOT)
      point_only.call(["Bed_D", mod, "#{mod}.cleat_front"], x, 880.0, 340.0, T_SCR)
      point_only.call(["Bed_D", mod, "#{mod}.rail_front"],  x, 920.0, 340.0, T_PILOT)
      n += 4
    end
  end
  SLATS.each do |slat, x, mod|
    point_only.call(["Bed_D", "D.slats", slat], x, 41.0,  380.0, T_SCR)
    point_only.call(["Bed_D", "D.slats", slat], x, 897.0, 380.0, T_SCR)
    point_only.call(["Bed_D", mod, "#{mod}.cleat_back"],  x, 41.0,  360.0, T_PILOT)
    point_only.call(["Bed_D", mod, "#{mod}.cleat_front"], x, 897.0, 360.0, T_PILOT)
    n += 4
  end
  raise "points sanity: #{n}" unless n == 88
  parts = finalize.call
  model.commit_operation
  JSON.generate({ "ok" => true, "chunk" => "screws", "points" => n, "parts" => parts,
                  "groups_total" => count_groups.call(model.entities) })
rescue => e
  model.abort_operation rescue nil
  JSON.generate({ "ok" => false, "error" => e.message, "backtrace" => (e.backtrace || []).first(3) })
end
result
```

- [ ] **Step 2: Сверить отчёт.** Expected: `ok:true`, `points:88`, `groups_total:233`; `parts`: у всех cuts 0, dV_exp 0.0, dV_fact 0.0; points по деталям: wall_back×3 — по 3; rail_front×3 — по 3; cleat_back: mod1 7 (3 пилота J5 + 4 пилота слатов 01–04), mod2 8 (3 + 5, слаты 05–09), mod3 7 (3 + 4, слаты 10–13); cleat_front — те же 7/8/7; slat_01..13 — по 2.
- [ ] **Step 3: Ledger.** Append: `Cam Task 7: complete (88 шурупных точек: J5 36 + J6 52; распределение по деталям по Expected; 233)`.

### Task 8: Чанк C6 — скриншоты и приёмка

**Files:** мутации видимости (2 операции) + чтение; Append: ledger

**Interfaces:** Consumes: вся присадка нанесена. Produces: кадры приёмки, чек-лист, возврат видимости.

- [ ] **Step 1: Кадр 1 — общий конструктив Bed_D.** Камеру поставить read-only-eval'ом (камера — не мутация, операция не нужна):

```ruby
eye = Geom::Point3d.new(11500 / 25.4, 3600 / 25.4, 2300 / 25.4)
tgt = Geom::Point3d.new(8996 / 25.4, 470 / 25.4, 260 / 25.4)
Sketchup.active_model.active_view.camera = Sketchup::Camera.new(eye, tgt, Z_AXIS)
"camera set"
```

Затем MCP `get_viewport_screenshot`. Expected на кадре: три модуля с вырезами на стенках/царгах/планках, точки присадки.
- [ ] **Step 2: Кадр 2 — стык mod1/mod2 крупно.** Камера eval'ом (read-only):

```ruby
eye = Geom::Point3d.new(9300 / 25.4, 2200 / 25.4, 900 / 25.4)
tgt = Geom::Point3d.new(8654 / 25.4, 500 / 25.4, 200 / 25.4)
Sketchup.active_model.active_view.camera = Sketchup::Camera.new(eye, tgt, Z_AXIS)
"camera set"
```

MCP `get_viewport_screenshot`. Expected: стыковая пласть Γ со шкантами (4 угловых + язычковый) и сквозными Ø7, устьевые точки.
- [ ] **Step 3: Кадр 3 — ламели с точками J6.** Операция-мутация видимости (`eval_ruby`, целиком):

```ruby
model = Sketchup.active_model
result = begin
  model.start_operation("MCP: Присадка D — видимость для кадра 3", true)
  model.layers["Ламели"].visible = true
  model.commit_operation
  "lamели on"
rescue => e
  model.abort_operation rescue nil
  "error: #{e.message}"
end
result
```

Камера сверху (read-only eval):

```ruby
eye = Geom::Point3d.new(8996 / 25.4, 470 / 25.4, 3000 / 25.4)
tgt = Geom::Point3d.new(8996 / 25.4, 470 / 25.4, 370 / 25.4)
Sketchup.active_model.active_view.camera = Sketchup::Camera.new(eye, tgt, Geom::Vector3d.new(0, 1, 0))
"camera set"
```

MCP `get_viewport_screenshot`. Expected: 13 ламелей, на каждой 2 точки (Y 41 и 897). Затем операция возврата (`eval_ruby`, тот же скелет операции с именем "MCP: Присадка D — возврат видимости" и строкой `model.layers["Ламели"].visible = false`):

```ruby
model = Sketchup.active_model
result = begin
  model.start_operation("MCP: Присадка D — возврат видимости", true)
  model.layers["Ламели"].visible = false
  model.commit_operation
  "ламели off"
rescue => e
  model.abort_operation rescue nil
  "error: #{e.message}"
end
result
```
- [ ] **Step 4: Чек-лист приёмки.** (а) на кадрах видны вырезы всех типов; (б) выключение/включение тега «Ø8×13 шкант пласть» (руками пользователя или eval-операцией с возвратом) меняет видимые точки — теги работают; (в) `list_layers`: видимость всех 8 старых тегов В ТОЧНОСТИ по before из Task 1 Step 5, все 8 новых тегов on; (г) `list_components`: 233, truncated=false.
- [ ] **Step 5: Ledger.** Append: `Cam Task 8: complete (кадры 1–3, чек-лист (а)–(г) пройден, видимость возвращена, 233 группы). ИТОГ ФАЗЫ: 222 выреза + 310 точек на 8 тегах в папке «Присадка D»; счётчики тегов: стакан 30, канал 30, шкант торец 48, шкант пласть 68, шток 30, Ø7 16, Ø4,5 44, Ø3 44; объёмные дельты по деталям — по Expected-таблицам Tasks 3–7. Модель НЕ сохранена — сохраняет пользователь.` Напомнить пользователю сохранить модель.

## Итоговые инварианты фазы (сверка в Task 8)

- Групп 233; bbox узлов/деталей не менялись; git не менялся (план коммитится до исполнения).
- Точек по тегам: Ø15×13 — 30; Ø8×36 — 30; Ø8×25 — 48; Ø8×13 — 68; Ø5×11,5 — 30; Ø7 — 16; Ø4,5 — 44; Ø3 — 44. Итого 310.
- Присадка направляющих: в 6 стенках Bed_D по-прежнему по 1 cline + 5 cpoint (поверх новых точек этой фазы).
- Ящики, фасады, Bed_A/B/C — не тронуты.

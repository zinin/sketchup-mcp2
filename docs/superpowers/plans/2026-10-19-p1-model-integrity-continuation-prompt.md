## TASK

Continue executing the implementation plan for the full-review fixes, part 1 — model integrity and safety net (branch `fix/p1-model-integrity`, SketchUp MCP project). Tasks 1–14 are implemented and reviewed. What is left: Task 15 (live verification in the user's SketchUp + test counts), the final whole-branch review with one fix wave, and finishing the branch (PR).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents and read-only git/grep)
- Call any `mcp__sketchup__*` tool (the user's live SketchUp is involved)
- Assume what task to work on next
- Push, open a PR, or call `gh`

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-10-19-p1-model-integrity-design.md`
- Plan: `docs/superpowers/plans/2026-10-19-p1-model-integrity.md` (Tasks 1–14 trimmed to commit links; Task 15 in full)
- SDD ledger (git-ignored, in the working tree): `.superpowers/sdd/2026-10-19-p1-model-integrity/progress.md` — first line names the plan; every task has a `complete` line; it holds the pre-flight scan, all `Ruling:` lines, every `minor (deferred)` finding, and a `## CHECKPOINT` section with the exact remaining steps and the extra live checks reviewers asked for. Read it fully — it is the source of truth for progress.
- Source review (untracked, keep it): `full-review/full-review-merged.md` — the merged three-model review; `M-xx` IDs in the spec refer to it.

Read the design, the plan and the ledger to understand the full picture.

## PROGRESS

**Completed tasks** (each: implementer → task review, all approved; commits on `fix/p1-model-integrity` after `caf3d0b`):
- [x] Task 1: mcp>=1.30, pydantic>=2.11, no [cli]; `uv sync --locked` in CI; weekly deps-latest; Dependabot — `3f4da01`
- [x] Task 2: seam / curved-rim classification helpers + `test/support/edge_fakes.rb` — `9180818`
- [x] Task 3: edge ops skip seams, fillet refuses curved rims, clean abort on a destroyed body, 30 s budget — `ca9001e`
- [x] Task 4: upper bounds for fillet segments, num_fingers, num_tails, create_component segments — `371094c`
- [x] Task 5: timeout error warns a mutating call may still commit — `aedf4f7`
- [x] Task 6: `set_material` on faces/edges (describe before commit), material resolution — `c53a5c4`
- [x] Task 7: delete/transform accept only groups and component instances — `79e16ac`
- [x] Task 8: refuse `.skp` export of an untitled model (reverses T-27) — `5b117c6`
- [x] Task 9: rollback table for all 11 mutating handlers — `ecefd0e`
- [x] Task 10: eval-gate / enable-confirm / undo pins — `6f5ad79`
- [x] Task 11: source-level contract tests + `READ_ONLY_TOOLS` — `3837eb7`
- [x] Task 12: wire-level contract harness + CI `contract` job — `e4c2f5d`
- [x] Task 13: README Security model, SSH tunnel, Settings/confirm text, strict entity-id wording — `f917f6d`
- [x] Task 14: TestPyPI hash check + local-wheel install; `SKETCHUP_MCP_SMOKE_REMOTE=1` — `f1b8b5a`

**Remaining:**
- [ ] Task 15: live verification + CLAUDE.md test counts (controller task in the main session — never a subagent)
- [ ] Final whole-branch review (opus) → ONE fix wave → one scoped re-review
- [ ] `superpowers:finishing-a-development-branch`

## SESSION CONTEXT

**Execution method.** The user chose subagent-driven development (`superpowers:subagent-driven-development`), workspace `.superpowers/sdd/2026-10-19-p1-model-integrity/` (briefs, reports, review packages live there). Branch was created with `git switch -c` in the main checkout (not a worktree) — the user's choice. Model choices so far: implementers sonnet (opus for Tasks 3, 9, 12), reviewers sonnet (opus for 3, 12). The final review must run on **opus** — never Fable (the user's global CLAUDE.md forbids Fable without explicit permission). Build/test commands in the main session go through the `build-forge:build-runner` agent.

**The live MCP server runs from this checkout.** `.mcp.json` starts it with `uv run --directory /opt/github/zinin/sketchup-mcp2 python -m sketchup_mcp` and `UV_PROJECT_ENVIRONMENT=/home/zinin/.venvs/sketchup-mcp2`. That venv is still on mcp 1.27.0; the next `/mcp` reconnect re-syncs it to the branch's `uv.lock` (mcp 1.30.0). Only the user can run `/mcp`. The SketchUp side runs the *installed* signed plugin 0.3.1 (`.rbe`); Task 15 hot-reloads the changed handler files by sending each file's source through `eval_ruby` (order: geometry, materials, operations, joints, export, dispatch). Tell the user SketchUp keeps the branch's handlers until it restarts.

**Live environment facts (verified):** SketchUp 26.1.256 (2026.1), Ruby 3.2.2, json 2.6.3, Windows; split host (Linux VM ↔ Windows SketchUp). The user's open model is an **untitled empty template** — do not run a `.skp` export before the hot reload (the old plugin would re-point the user's document to %TEMP%). Name every probe object `probe_*`, wrap experiments in `start_operation … abort_operation` where possible, and erase probes afterwards (erase entities named `probe_*`, `definitions.purge_unused`, remove any material you created). The undo stack already contains review probe operations.

**Facts found live during this work (not all are in the docs):**
- `Group#subtract` returning `nil` can invalidate BOTH the cutter and the body (cylinder seam at 15°) — the root cause of M-01.
- Default primitive dihedrals: cylinder rims 90° / seams 15°; cone rim 116.4° / seams 13.4°; sphere all edges 2.2–22.4° → threshold 25°.
- Per-segment fillet cannot cut tessellated rims; a Follow Me sweep of one profile around a closed rim produced a non-manifold cutter (profile-shaped hole at the seam; starting at an edge midpoint and `find_faces` capping did not fix it) — deferred follow-up.
- Chamfer on cylinder rims per segment: manifold, ~10 % less material than ideal, 48 tiny edges at joints.
- `Materials#[]` is case-INSENSITIVE (`"red"` finds `"Red"`); `add("red")` with `"Red"` present creates `"red1"`. Vertex/Face Ruby objects are identity-stable (`equal?`, `Array#&`, Hash keys work).
- `consume_pending_write` is not quadratic (0.6 ms for 43 MiB in SketchUp's Ruby) — a GLM finding that was refuted.

**Rulings already made (all in the ledger; report them to the user at the end under "Rulings I made"):** Task 12 tolerates an exception only from `get_viewport_screenshot`; Task 12 also asserts handler method == wire name (one pinned exception); "expected argument names" = args arrive unchanged (handler-side key reading is M-29, P2); Task 3 test_tool_descriptions pin update accepted; Task 3 "stopped after k of N" counts processed edges; Task 6 keeps "(#rrggbb)" in the docstring; Task 9 success half pinned for 3 handlers only.

**Fix-wave candidates already flagged for the final review** (from the ledger's deferred minors): CLAUDE.md:29 `.to_i` rationale should cite `"12abc".to_i == 12`; `test/test_dispatch_routing.rb` `File.read` needs `encoding: "UTF-8"`; `set_material` docstring/`Field` wording vs case-insensitive `Materials#[]`; the `setup/teardown/stub_singleton` trio is copied in 8 test files (shared `test/support` helper); release.md §4 hash check passes vacuously on an empty `dist/` + failed lookup; 7 handlers still `describe_entity` after commit (known M-16, P2 — probably park).

**User preferences:** answer in Russian; code/docs in English, code comments match surroundings. Per the user's CLAUDE.md: before opening the PR, `git rm` everything under `docs/superpowers/` (spec, plan, this prompt) and commit, so plan documents never appear in the PR diff. GitHub has a Codex reviewer that reviews automatically when the PR opens; never post `@codex review` without the user's permission. Untracked files that must never be committed: `.venv.broken-task8/`, `full-review/`, the two `docs/superpowers/plans/2026-08-24-*` prompt files.

**What comes after this branch (agreed with the user):** part 2 — world coordinates for nested entities (M-03, contract change); part 3 — joinery redesign (M-02, needs the user's joint semantics); part 4 — socket authentication (M-06, needs the user's token UX; a client-sends-token scheme leaks to an impostor holding the port, so prefer challenge-response); part 5 — release 0.4.0 (raise both floors, Trusted Publishing M-10). P2/P3 from the merged review in later sessions. Each part: its own branch (`git switch -c`) and PR.

## PLAN QUALITY WARNING

The plan was written for a large task and may contain:
- Errors or inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the documents listed above (design, plan, ledger)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"

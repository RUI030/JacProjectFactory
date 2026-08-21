# Antipatterns

A running catalog of mistakes we made in this codebase and how we fixed them. Unlike `DECISIONS.md` (load-bearing calls we made deliberately, append-only), this is patterns we wrote, recognized as wrong, and corrected — kept so we don't reintroduce them elsewhere in the pipeline (Factory will have its own walkers; this is exactly the kind of thing to avoid repeating there).

Each entry: what the bad pattern looked like, what replaced it, and why the replacement is better. Newest at the bottom.

---

## Storing walker-run data on graph nodes, then re-fetching it via backward traversal

**Where:** `customer/main.jac`, the `Customer` walker (Persona → Wish → Spec → Emit chain).

**Before** — each node carried its own slice of the run's data, so any later phase that needed earlier data had to walk backward through the graph to find it:

```jac
node PersonaNode {
    has seed: PersonaSeed;
}
node WishNode {
    has wish_text: str = "";
}
node SpecNode {
    has project_name: str = "";
    has requirement_md: str = "";
    has smoke_yaml: str = "";
}

can on_emit with EmitNode entry {
    spec_parents = [here <--[?:SpecNode]];
    if not spec_parents { disengage; }
    sp = spec_parents[0];
    wish_parents = [sp <--[?:WishNode]];
    if not wish_parents { disengage; }
    wp = wish_parents[0];
    persona_parents = [wp <--[?:PersonaNode]];
    if not persona_parents { disengage; }
    pp = persona_parents[0];

    # ... finally, only now can we read sp.project_name, wp.wish_text, pp.seed.id
}
```

Three near-identical blocks, each doing: query backward with a type filter → guard against an empty result → index `[0]`. The guards were defending against a graph shape that can never actually occur (the chain is linear and built by this same walker one step earlier in the same run) — dead code paths that exist only because the data was in the wrong place.

**After** — the walker carries its own run state directly; nodes become pure phase markers:

```jac
node PersonaNode {}
node WishNode {}
node SpecNode {}
node EmitNode {}

walker Customer {
    has persona: PersonaSeed = PersonaSeed(id="", title="", background="");
    has wish_text: str = "";
    has project_name: str = "";
    has requirement_md: str = "";
    has smoke_yaml: str = "";
    ...

can on_emit with EmitNode entry {
    base = Path(self.out_root);
    out_dir = base / self.project_name;
    # self.wish_text, self.requirement_md, self.smoke_yaml, self.persona.id
    # are all just... there.
}
```

**Why the fix is better:**
- Removes all three backward-traversal blocks and their guard clauses — `on_emit` shrank from ~30 lines to reading fields directly.
- Matches the documented design intent already stated in `docs/PIPELINE.md`: "one walker traversing it, **carrying the run's state**." The node-field version quietly contradicted the pipeline's own stated architecture.
- The guard clauses (`if not parents { disengage; }`) were validating a scenario that structurally cannot happen on a non-branching chain — itself a smell (see `CLAUDE.md`: "Don't add error handling... for scenarios that can't happen").
- Nodes now do exactly one job — give the FSM a traversable shape — instead of two (shape *and* data storage), which is what they should have been from the start on a graph this simple. This only becomes wrong when the graph is a straight line; for a graph with real branching or multiple walkers needing to query the same persisted node later, storing data on nodes would be the correct call — reach for it only when you're actually querying the graph independently of a single walker's run.

_2026-08-20._

---

## Trusting `jac check`'s exit code without `-e`

**Where:** `factory/main.jac`, `run_gate` for Model and Endpoints phases.

**Before** — Factory's gate ran plain `jac check .` and treated exit 0 as pass:

```jac
r = run_gate(["jac", "check", "."], self.work_dir);   # exits 0 even on errors!
gate.passed = (r.returncode == 0);
```

Symptoms: Model and Endpoints's gates reported PASS while the generated `main.jac` had 10 type errors:
```
=================================== FAILURES ===================================
✖ Error: error[E1030]: Type "object" has no attribute "end_time"
...
main.jac - 10 errors, 15 warnings
========================= 1 passed, 2 failed in 0.51s ==========================
```
The trajectory dutifully recorded `outcome: "pass"` and the walker advanced to the next phase. Downstream failures then cascaded confusingly (Tests couldn't figure out how to call code that was itself broken).

**After** — pass `-e`:

```jac
r = run_gate(["jac", "check", "-e", "."], self.work_dir);
```

`jac check -e` correctly exits 1 on errors. Same command otherwise.

**Why the fix is better:**
- No silent failures. The gate now catches what its documentation implies it should.
- `jac test` already exits non-zero correctly, so this only needed fixing on the check side.
- We wasted several full pipeline runs (30+ minutes each) chasing "why is Endpoints producing broken code" before realizing the gate itself was lying. Lesson: when a gate consistently passes but downstream keeps breaking, verify the gate's exit-code contract first. Don't assume standard CLI conventions.

_2026-08-20._

---

## Tail-truncating diagnostics to feed the repair loop

**Where:** `factory/main.jac`, `model_repair_task` / `endpoints_repair_task` / `tests_repair_task`.

**Before** — repair task took the *tail* of the failing gate's output:

```jac
def model_repair_task(failure_output: str) -> str {
    return f"""... diagnostics:
{failure_output[-4000:]}
...""";
}
```

Symptom: on verbose failures (10 errors × ~450 chars each + header + footer > 4000 chars), the tail slice included the "failed files" summary and last few errors but **dropped the first few errors** — which are usually the root cause. Later errors typically cascade from them. Model then repaired symptoms instead of the actual bug.

Also inconsistent: the trajectory record used `gate.output[:4000]` (head), the repair task used `[-4000:]` (tail). Different context for the same failure.

**After** — head slice, larger cap:

```jac
{failure_output[:8000]}   // in every repair task
"diagnostics": gate.output[:8000],   // in trajectory
```

**Why the fix is better:**
- First errors reach the model — usually the root cause.
- Trajectory and repair task see the same content — analytics stays honest.
- 8000 chars covers most real jac check failures fully.
- Same fix applies whenever the tool being diagnosed lists most-important-first (which is most linters/checkers).

_2026-08-20._

---

## Fall-through after `visit` in a walker ability's pass branch

**Where:** `factory/main.jac`, `on_model` / `on_endpoints` originally.

**Before** — the pass branch had an `if` but no `else`, and control fell through into the fail logic:

```jac
if gate.passed {
    print(f"[model] gate PASS on attempt {self.phase_attempts}");
    visit [here -->[?:EndpointsNode]];
}
print(f"[model] gate FAIL on attempt {self.phase_attempts}");   // ← always runs
self.model_last_failure = gate.output;
visit [here -->[?:DiagnoseModelNode]];                            // ← always scheduled
```

Symptom: on a pass, the walker printed both "PASS" and "FAIL" and scheduled visits to BOTH the next phase AND DiagnoseModel. The walker then visited both in sequence. We got lucky because the next phase (Endpoints) disengaged before DiagnoseModel got its turn — but under different orderings, Diagnose would have run needlessly on a passing state, wasting an LLM call.

**After** — explicit `else`:

```jac
if gate.passed {
    ...
    visit [here -->[?:EndpointsNode]];
} else {
    ...
    visit [here -->[?:DiagnoseModelNode]];
}
```

**Why the fix is better:**
- Walker abilities are ordinary Jac code — no implicit "return after `visit`". `visit` schedules the next node without stopping the current ability from running.
- The `if` shape doesn't hint at the branching semantics — an `else` (or an explicit `return`) makes it read exactly the way it executes.
- Same shape needed at every branching walker ability. Cheap to make it a rule.

_2026-08-20._

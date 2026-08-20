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

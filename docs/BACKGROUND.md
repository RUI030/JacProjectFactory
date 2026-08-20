# JacProjectFactory — Background

## Goal

Train an LLM that can genuinely write **Jac** (the Jaseci programming language). Jac is new and underrepresented in pretraining data, so off-the-shelf models — especially small/local ones — don't know it. To fix that we need a large training dataset of **Jac code that actually runs**, and the most valuable unit of data is not isolated snippets but **complete, working, repo-level projects** (real `jac.toml`, walkers, endpoints, tests — the whole thing).

JacProjectFactory is the data-generation pipeline that produces those repos at scale.

## What we know so far

- **Opus + Jac skill files works.** A frontier model given the curated Jac skills (cheatsheet, scaffolding, endpoints, client components, debugging, etc.) can vibe-code a working fullstack Jac project. This proves the skills contain enough signal to write correct Jac.
- **Frontier models don't scale for datagen.** Generating thousands of repos with Opus is too expensive. Scaling requires a **local model**, which is much weaker.
- **Local models fail in predictable ways.** Observed when a local model tried to reimplement an Opus-built project:
  1. **Syntax bleed** — it falls back to Python/TypeScript syntax instead of Jac.
  2. **Hand-rolled scaffolding** — instead of using `jac create`, it invents its own project structure, which breaks everything downstream and makes batch generation non-uniform.
  3. **No self-correction discipline** — it doesn't reliably read the right reference material or run `jac check` before piling on more broken code.

## The core idea: a deterministic pipeline

Instead of handing the small model an open-ended "build this app" prompt, we wrap it in a **deterministic orchestrator** (a finite state machine, implemented as a Jac OSP graph). The orchestrator — not the model — decides what phase comes next, what context is loaded, and what must pass before advancing. The model only does the creative work *inside* each phase.

Key properties:

- **Verifiable at every step.** `jac check`, `jac test`, and a runtime smoke test are the ground-truth filters. Nothing enters the marketplace unverified.
- **Uniform starting point.** Deterministic scaffolding via `jac create --kind service` — every sample shares canonical structure.
- **Phase-scoped context.** Small models drown in context; each phase loads only the skills it needs.
- **Bounded autonomy.** The model can't wander — the FSM owns control flow, the model owns code.
- **Nothing is thrown away.** Failed samples still carry RL and diagnostic signal, so they route to `repaircenter/` or `archived/` rather than being discarded.

Concrete pipeline shape lives in [`PIPELINE.md`](PIPELINE.md).

## Decisions

The load-bearing calls we've made — harness choice, session model, orchestrator-in-Jac, output bucket policy, and so on — are logged with their reasoning in [`DECISIONS.md`](DECISIONS.md).

## Open questions

- **When (if ever) to add the teacher stage?** Decide after measuring v1 pure-local pass rates.
- **Library-import policy for v2 fullstack.** In v1 (backend-only) we hard-rule out npm and JSX. For v2 the tradeoff is real: some npm libraries are genuinely useful for client code and shipping them makes for better training samples, but uncontrolled imports hurt output uniformity. Deferred until v2 begins.

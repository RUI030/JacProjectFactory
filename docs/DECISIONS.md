# Decisions

Load-bearing calls we've made and why. Append-only — new decisions go at the bottom, existing ones only get amended (with a note) or superseded.

For scope and motivation see [`BACKGROUND.md`](BACKGROUND.md); for the build pipeline shape see [`PIPELINE.md`](PIPELINE.md).

---

## Harness: `unsloth start claude` (headless)
Unsloth's launcher serves a local model and auto-wires Claude Code to it, so the pipeline reuses everything that already works with Opus + Jac skills. Only the model swaps. Fallbacks — `unsloth start opencode` / `codex`, or a custom minimal tool loop — are a one-line switch if the local model chokes on Claude Code's tool schema. _2026-08-19._

## Session model: fresh per phase, resume within a phase
Each phase starts a clean `claude -p` session; within a phase's fix loop we resume via `--session-id` / `--resume` so the model remembers prior repair attempts. A shared cross-phase session drags fix-loop noise into unrelated phases and breaks disk-state reproducibility of a phase. _2026-08-19._

## Compute reuse via prefix caching, not session continuity
Every LLM phase's prompt begins with an identical stable prefix (system prompt, core cheatsheet, project-kinds guide, repo tour). `llama-server`'s KV cache reuses the shared prefix across fresh invocations. Studio stays persistent to keep the cache warm. _2026-08-19._

## FSM is code, not an LLM
Control flow is deterministic by construction. A frontier model as orchestrator would reintroduce cost and non-determinism in the one place we explicitly built determinism. Models only work inside phases. _2026-08-19._

## Pure-local first; teacher is a later, tagged stage
v1 runs entirely on the local model, with `jac check` / `jac test` as the quality filter. A frontier teacher (Opus) is added only if measured pass rate is too low, and strictly as a tagged post-hoc stage. Teacher-touched samples must be labeled distinctly from pure-local ones — they have different training value and provenance must stay clean. _2026-08-19._

## v1 target: backend-only Jac projects
Proving state transitions, gate logic, skill injection, and fix loops on `jac create --kind service` is cheaper than debugging orchestrator bugs and small-model failures on a fullstack repo simultaneously. Fullstack is v2 — adding phases, not redesigning the machine. _2026-08-19._

## Orchestrator is itself a Jac graph
Phase-nodes plus transition-edges plus one walker per run is a natural OSP fit. Dogfoods Jac and makes the pipeline itself a non-trivial reference sample. Parallel batches are N walkers on the same graph. _2026-08-19._

## Two-stage pipeline: Customer → Factory
Spec generation (`customer/`) and repo building (`factory/`) have different models, cache lifetimes, and failure modes. A bad spec is unrecoverable; a bad build is retryable. They must not share a process. _2026-08-19._

## Naming: the factory metaphor
Consistent vocabulary is easier to reason about than a mix of technical and metaphorical names. Customer orders a spec; Factory builds; outputs land in `marketplace/`, `repaircenter/`, `refurbished/`, or `archived/`. Same `<name>` across buckets so a project's journey is traceable. _2026-08-19._

## Nothing is thrown away — four buckets
Failed samples still carry RL and diagnostic signal. `marketplace/` = passed every gate on first build. `repaircenter/` = passed at least one gate before capping (awaiting repair). `refurbished/` = a repair pass got every gate green. `archived/` = never passed a gate, or a repair attempt gave up. Archived is terminal: we don't retry it. _2026-08-19._

## Skill injection: preloaded core + on-demand discovery
Each phase preloads a fixed set of core skills into its (byte-stable) prompt prefix. Beyond that, the system prompt tells the model where the skills directory is and encourages it to read others via its file tool when it needs deeper guidance. This is not byllm-as-router: the FSM still owns control flow, the preload keeps critical context always present, and on-demand reads happen inside a phase — never across phases — so prefix caching is preserved. If we ever want deterministic per-run *preload* selection, the hook is a `skills_hint: [...]` field in the spec, decided once by Customer and read deterministically by Factory.
_2026-08-19; supersedes "byllm does not choose skills" (same date), which was overly restrictive — the earlier framing conflated FSM-level routing with in-phase file reads._

## One model, one server, many clients
Unsloth Studio runs persistently on `localhost:8888` and exposes OpenAI + Anthropic compatible endpoints. Claude Code, byllm, and any ad-hoc HTTP client all hit the same server. Concurrent requests supported; no restart between callers. _2026-08-19._

## Repair is a separate pipeline
Repair takes a `repaircenter/` sample and drives a different model, with a different budget and success criteria, to promote to `refurbished/` or push to `archived/`. It does not share Factory's FSM. Its own doc — `REPAIR.md` — when we design it. _2026-08-19._

## Customer: three stages, persona → wish → spec
Spec generation runs as three sequenced walker nodes. **Persona** picks a seed from `customer/personas/seeds.md`. **Wish** drafts a first-person, natural-language description of the app the persona wants. **Spec** produces the structured `requirement.md` + `smoke.yaml` from the wish. Each step is a smaller LLM task the local model handles more reliably than one "draft a full spec" prompt, and the wish artifact is itself training-valuable (natural request → structured spec is a useful pair). Full shape lives in [`CUSTOMER.md`](CUSTOMER.md). _2026-08-19._

## Complexity is an upper-bound hint, not a strict target
The orchestrator hands each Customer run a complexity ceiling (`tiny`, `small`, `medium`). `small` means the walker may produce tiny or small; `medium` covers tiny through medium. Softens the constraint so the wish can breathe naturally, while still letting us steer dataset curriculum by capping the max. _2026-08-19._

## Project names are semantic slugs derived from the wish
Spec walker names each project with a human-readable slug based on the wish (e.g. `grad-student-paper-library`). If the slug collides with an existing entry in `specs/`, orchestrator appends `-2`, `-3`, etc. No hashes — readability beats guaranteed first-attempt uniqueness. _2026-08-19._

## v1 Customer templates deferred
Customer starts without template exemplars; `CUSTOMER.md`'s schema is its only reference. If the local model's spec output proves inconsistent, hand-curated templates get added under `customer/templates/<complexity>/<name>/`. Deferring keeps v1 lean and gives us real signal on what the model actually needs help with. _2026-08-19._

## Specs are framework-agnostic; Factory owns the wire shape
Customer's `requirement.md` and `smoke.yaml` describe *capabilities* — an endpoint's name, purpose, inputs, output, behavior — not HTTP methods, URL paths, or Jac's walker-vs-function distinction. Factory resolves each capability to a concrete endpoint (walker vs function chosen from behavior) and translates the fixed smoke-assertion vocabulary (`expect_success`, `expect_output_contains`, `expect_output_length`, …) into the actual response-envelope checks. Rationale: leaking Jac vocabulary into Customer would lock the spec to one target framework, and — as the first Customer run demonstrated — a small local model tends to reach for REST/CRUD conventions from its training data whenever HTTP paths and methods are on the table. Keeping the spec at the capability layer sidesteps both problems. _2026-08-19._

## Mistakes get a separate catalog, not entries here
`DECISIONS.md` is calls we made deliberately and stand behind. Patterns we wrote, recognized as wrong, and replaced (e.g. Customer's original node-stores-data-plus-backward-traversal design) go in [`ANTIPATTERNS.md`](ANTIPATTERNS.md) instead, with a before/after code example each — a running catalog so the same mistake doesn't get reintroduced in Factory or Repair. _2026-08-20._

## Diagnose nodes are one-per-stage, not a shared Fix node
Model/Endpoints/Tests/Smoke each get their own `Diagnose: X` node with a single edge back to `X`, instead of one shared `Fix` node all four route through. A shared node would have to carry "which phase do I resume into" as hidden walker state — exactly the ambiguity that came up when reading the original diagram, which only ever drew one representative `Fix --> Model` edge and left the other three implicit. A dedicated node per stage makes the retry a literal graph cycle (visible in `jac dot`), lets each stage's diagnose skills/behavior diverge independently, and — bonus, spotted once the nodes were separated — even the bucket-on-cap decision turns out to need no shared router at all: `DiagnoseModel` capping always means archived (it's the first gate), any other `Diagnose` node capping always means repaircenter (reaching it required an earlier gate to pass). Static per node, no runtime flag. _2026-08-20._

## Design is its own phase, ahead of Scaffold
Customer's spec is deliberately framework-agnostic — no walker-vs-function choice, no concrete node/edge names (see "Specs are framework-agnostic" above). Something has to make those Jac-specific calls before code gets written; folding that reasoning invisibly into the Model phase's prompt would make it unrepeatable and untraceable. Design does it explicitly: reads the spec folder, writes a `pipeline.md` (Mermaid diagram of the planned node/edge shape and each capability's Jac form) plus a jac-annotated copy of `requirement.md`, both into the destination fp — never touching Customer's original. Every later phase reads the annotated copy. Bonus: `pipeline.md` and a drafted `README.md` get copied into the final repo, so every generated sample also has real project-level documentation, not just source. _2026-08-20._

## Headless `claude -p` runs with `--dangerously-skip-permissions`
Without it, Claude Code pauses for interactive approval before file edits and shell commands — exactly what every LLM phase needs to do — and a headless call blocked on a prompt no one can answer hangs the pipeline forever. Judged safe here specifically because every phase operates inside a repo Factory itself scaffolded moments earlier into a throwaway destination path: nothing pre-existing to damage, no network access needed beyond the local Unsloth server, and nothing the model does is trusted anyway until `jac check`/`jac test`/smoke assertions say so afterward. The orchestrator also never treats the model's own "I'm done" as a signal to advance — every phase re-runs its gate command itself and reads the exit code; `claude -p` returning only means the agent stopped taking turns. _2026-08-20._

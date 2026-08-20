# JacProjectFactory

You are working on the pipeline itself, not on a Jac project. This repo is a deterministic orchestrator (an FSM) that drives a small local model to generate real, runnable, repo-level Jac projects for training data. Read `docs/BACKGROUND.md` before making non-trivial changes — the "why" behind most decisions lives there.

## Rules of the road

**The FSM is code, not an LLM.** Control flow is deterministic. If a design idea starts with "let the model decide when to...", push back or replace it with an explicit state and a gate. Non-determinism in the orchestrator defeats the point of the project.

**Scaffolding is never LLM-generated.** Generated repos always start from `jac create <name> --kind service`. Don't add code paths that let the model invent project structure.

**Gates are ground truth.** `jac check`, `jac test`, and (later) runtime smoke tests decide whether a phase passes. Don't route around a failing gate; either fix the underlying issue or fail the sample.

**Keep phase context small.** Each FSM state loads only the Jac skills that phase actually needs. Don't stuff every skill into every prompt just because it's easier — small models drown in it, and it defeats prefix caching.

**Prefix stability matters.** Prompts are structured as `stable core prefix` + `phase-specific skills` + `phase task`. Don't shuffle the core prefix around between phases; `llama-server`'s KV cache reuse depends on the bytes being identical.

## Layout

- `docs/` — design docs. `BACKGROUND.md` for motivation and scope, `DECISIONS.md` for the load-bearing decisions log, `ANTIPATTERNS.md` for mistakes we made and fixed, `PIPELINE.md` for Factory's shape, `CUSTOMER.md` for Customer's shape.
- `customer/` — Customer stage (persona → wish → spec). `customer/specs/` is Customer's output and Factory's input — each `customer/specs/<name>/` has `wish.md`, `requirement.md`, `smoke.yaml`, `meta.json`. `factory/` — Factory build pipeline. Repair, when it exists, lives in its own folder.
- Generated projects land in `factory/output/{marketplace,repaircenter,archived}/<name>/`. Don't confuse pipeline source (this repo) with generated samples (`factory/output/`).

## Don'ts

- Don't reach for `jac-by-llm` here — it's a Jac language feature, not a coding-agent framework, and it's not what this project uses.
- Don't add a supervisor/teacher model into the core loop. If we ever add one, it goes as a tagged post-hoc stage so pure-local samples stay distinguishable from teacher-touched ones.
- Don't create planning or status Markdown files unless asked. Ephemeral notes belong in the conversation.

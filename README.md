# JacProjectFactory

A pipeline for generating runnable, repo-level [Jac](https://jac-lang.org) projects with a small local model, for use as LLM training data.

Frontier models with the Jac skill files can already build working fullstack Jac apps. That doesn't scale to the thousands of repos we need. Local models are cheap enough to scale but too weak to build a real project on their own — they bleed syntax from other languages, invent broken scaffolding, and don't self-correct.

JacProjectFactory wraps the local model in a deterministic finite state machine. The FSM handles scaffolding, decides which skills to load for each phase, and gates progress on `jac check` / `jac test`. The model only does the coding inside each phase. Every repo that comes out has actually compiled and run.

For the full design and the reasoning behind it, see [`docs/BACKGROUND.md`](docs/BACKGROUND.md).

## Status

Early. Docs and design first; pipeline code next.

## Requirements (planned)

- [Unsloth](https://unsloth.ai) — serves the local model and launches Claude Code against it via `unsloth start claude`.
- [jaclang](https://jac-lang.org) — provides `jac create`, `jac check`, `jac test`, and the skill files the pipeline injects.
- Claude Code — the coding-agent harness the FSM drives in headless mode (`claude -p`).

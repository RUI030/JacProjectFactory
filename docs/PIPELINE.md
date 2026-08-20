# Pipeline

The v1 build pipeline generates backend-only Jac projects. Scope, motivation, and the top-level decisions live in [`BACKGROUND.md`](BACKGROUND.md); this doc describes the shape.

The pipeline runs in two stages, both implemented in Jac using OSP:

- **`customer/`** — a walker that drafts requirement specs and writes them into a versioned `customer/specs/` bank. (The "Customer" places an order at the factory.)
- **`factory/`** — a walker that reads one spec and produces one candidate repo.

They stay separate because specs and builds have different models, different cache lifetimes, and different failure modes. A bad spec is unrecoverable; a bad build is retryable. Regenerating the spec bank must not touch the build pipeline.

Repair is a **third**, independent pipeline. It takes a `repaircenter/` sample and drives a different model with a different budget to promote it to `refurbished/` or push it to `archived/`. It does not share Factory's FSM — its shape will live in `REPAIR.md` when we design it.

## Input and output

Factory's contract, end to end:

- **Input:** a spec folder — `customer/specs/<name>/` containing `requirement.md` and `smoke.yaml` (Customer's output; Factory never mutates these).
- **Destination:** a working filesystem path, `factory/output/.build/<name>/`, that Factory owns for the duration of one run.
- **Output:** one of `factory/output/{marketplace,repaircenter,archived}/<name>/`, each shaped `{repo/, spec/, trajectory.jsonl, meta.json}` — where `repo/` is a real, runnable Jac project that additionally contains a `README.md` and a `pipeline.md` (the project's own design doc, see Design below) at its root, alongside the generated Jac source.

Every node below states its own input/output against that same destination path, so it's always clear what a node reads and what it's expected to leave behind.

## The build graph

The orchestrator is a Jac graph. One project generation is one walker traversing it, carrying the run's state (spec id, per-node session ids, per-gate counters, global counter, trajectory — see [`ANTIPATTERNS.md`](ANTIPATTERNS.md) for why this lives on the walker and not on nodes). Running N repos in parallel is N walkers on the same graph.

Each gated LLM phase (Model, Endpoints, Tests, Smoke) has its **own** Diagnose node — not one shared `Fix` node. A shared node would have to carry "which phase do I resume into" as hidden state; a dedicated `Diagnose: X` node just has one edge back to `X`, so the retry is a plain graph cycle instead of a dispatch table. There's no shared "Route" node either: each `Diagnose` node writes straight to its own (fixed) bucket on cap-out — see the diagram.

```mermaid
flowchart TD
    Start([spec folder: requirement.md + smoke.yaml]) --> Design
    Design["<b>Design</b><br/>drafts pipeline.md (mermaid) +<br/>jac-annotated requirement.md +<br/>README.md draft, into destination fp"] --> Scaffold
    Scaffold["<b>Scaffold</b><br/>jac create --kind service<br/><i>no LLM</i>"] --> Model

    Model["<b>Model</b><br/>node/edge graph<br/>+ node-edge-patterns, has-fields, types"] --> CkA{jac check}
    CkA -- pass --> Endp
    CkA -- fail --> DiagModel["Diagnose: Model<br/>+ jac-debugging"]
    DiagModel -->|attempts ≤ 5| Model
    DiagModel -->|attempts > 5| AR1

    Endp["<b>Endpoints</b><br/>walkers + functions<br/>+ walker-patterns, sv-endpoints, sv-persistence"] --> CkB{jac check}
    CkB -- pass --> Tests
    CkB -- fail --> DiagEndp["Diagnose: Endpoints<br/>+ jac-debugging"]
    DiagEndp -->|attempts ≤ 5| Endp
    DiagEndp -->|attempts > 5| RC1[("repaircenter")]

    Tests["<b>Tests</b><br/>+ jac-testing"] --> TGate{jac test}
    TGate -- pass --> Smoke
    TGate -- fail --> DiagTests["Diagnose: Tests<br/>+ jac-debugging"]
    DiagTests -->|attempts ≤ 5| Tests
    DiagTests -->|attempts > 5| RC1

    Smoke["<b>Smoke</b><br/>jac start + curl<br/><i>no LLM to run — repair only</i>"] --> SGate{200 + shape}
    SGate -- pass --> Harvest
    SGate -- fail --> DiagSmoke["Diagnose: Smoke<br/>+ sv-endpoints, sv-persistence, jac-debugging"]
    DiagSmoke -->|attempts ≤ 5| Smoke
    DiagSmoke -->|attempts > 5| RC1

    Harvest([Harvest]) --> MP[("marketplace")]
    Scaffold -- fails --> AR1[("archived")]

    classDef llm fill:#e8f0ff,stroke:#4d7dc9
    classDef gate fill:#fff4d6,stroke:#c9a94d
    classDef fix fill:#ffe4e4,stroke:#c94d4d
    classDef det fill:#e4f7e4,stroke:#4dc94d
    classDef bucket fill:#f0e8ff,stroke:#8d4dc9
    class Design,Model,Endp,Tests llm
    class CkA,CkB,TGate,SGate gate
    class DiagModel,DiagEndp,DiagTests,DiagSmoke fix
    class Scaffold,Smoke det
    class MP,AR1,RC1 bucket
```

Blue = LLM phase, green = deterministic, yellow = gate, red = diagnose-and-retry, purple = terminal bucket. `archived`/`repaircenter`/`marketplace` are shared terminal nodes (multiple edges converging on one is fine — there's no decision happening there, just several static, hardcoded destinations landing on the same outcome). `DiagnoseModel` is the only diagnose node that can cap out with zero gates ever passed, so it's the only one wired to `archived`; the other three can only be reached after an earlier gate already passed, so they're only ever wired to `repaircenter`.

### Design: turning a framework-agnostic spec into a Jac plan

Customer's `requirement.md` deliberately has no Jac vocabulary in it (see "Specs are framework-agnostic" in `DECISIONS.md`) — no walker-vs-function choice, no concrete node/edge names. Something has to make those calls before code gets written, and burying that reasoning inside the Model phase's prompt makes it invisible and unrepeatable. Design is that phase, made explicit:

- **Input:** the spec folder (`requirement.md`, `smoke.yaml`).
- **Output**, all written into the destination fp:
  - `pipeline.md` — a Mermaid diagram plus short prose: the entities and their node/edge shape, and for each capability, its concrete Jac form (walker or function) and why.
  - `requirement.md` (Factory's own copy, jac-annotated) — the same spec, with the framework-agnostic capability descriptions now carrying the concrete Jac decisions from `pipeline.md`. Customer's original in `customer/specs/<name>/` is never touched.
  - `README.md` (draft) — a project-level description, later copied into the generated repo as-is.
- **Gate:** deterministic — `pipeline.md` parses as valid Markdown containing at least one fenced ` ```mermaid ` block, and the jac-annotated `requirement.md` lists a Jac form for every capability named in the original. No LLM repair loop here: if Design's output doesn't meet that bar, Diagnose: Model's first attempt gets the failure as extra context (Model is the first phase that actually depends on Design's output being sound), rather than adding a fifth Diagnose node for a phase with no code to check yet.

Every later LLM phase (Model, Endpoints, Tests) reads the **jac-annotated** `requirement.md` from the destination fp, not Customer's original — that's the one place the framework-agnostic-to-Jac translation happens, and every phase downstream of Design sees it already resolved.

## Nodes at a glance

| Node | LLM? | Input | Output | Gate |
|---|---|---|---|---|
| Design | yes | spec folder | `pipeline.md`, jac-annotated `requirement.md`, `README.md` draft (destination fp) | valid mermaid + every capability has a Jac form |
| Scaffold | no | destination fp | `jac create --kind service` tree at destination fp | `jac.toml` exists |
| Model | yes | repo + jac-annotated `requirement.md` (data model) | node/edge graph types in repo | `jac check` |
| Diagnose: Model | yes | failing `jac check` output, attempt count | repaired repo (resumed session) | — |
| Endpoints | yes | repo (with model types) + `requirement.md` (endpoints) | walkers/functions in repo | `jac check` |
| Diagnose: Endpoints | yes | failing `jac check` output | repaired repo | — |
| Tests | yes | repo + `requirement.md` (test scenarios) | test file(s) in repo | `jac test` |
| Diagnose: Tests | yes | failing `jac test` output | repaired repo | — |
| Smoke | no | running repo + `smoke.yaml` | pass/fail per assertion | HTTP response shape |
| Diagnose: Smoke | yes | failing assertions | repaired repo | — |
| Harvest | no | repo + trajectory + spec | `factory/output/<bucket>/<name>/{repo/ (+README.md, pipeline.md), spec/, trajectory.jsonl, meta.json}` | — |

## Diagnose-loop rules

- **Per-gate counter, starts at 0 when the phase is entered, lives on the walker.**
- On gate failure: the phase node visits its own `Diagnose: X` node (a type-filtered edge, e.g. `visit [here --> (`?DiagnoseModel)];` — never an unfiltered `visit [here -->]`, since a phase node has two outgoing edges: forward-on-pass and diagnose-on-fail).
- `Diagnose: X` checks both caps (see below) before doing anything else. Under cap: increments the counter, records the failing output as a trajectory entry, drives one repair round (`claude -p --resume <session>`), then visits back to `X` to re-run the gate. Over cap: writes to its bucket (`DiagnoseModel` → `archived`, always; the other three → `repaircenter`, always — see the diagram) and disengages. No routing decision at runtime, just a fixed bucket per node.
- The model's session is resumed within a phase (`claude -p --session-id <id>` on the first attempt, `--resume <id>` on every retry) so it remembers prior attempts. A new phase starts a fresh session.
- **Cap per gate: 5.** Exceeding it routes the sample to a non-marketplace bucket (see below); it is not thrown away.
- **Global cap per run: 20 attempts total**, tracked on the walker across every stage. Catches slow-progress pathological runs that keep barely surviving each gate.
- Advancing to a new phase resets that phase's counter to 0 (it's a fresh local count each time `Diagnose: X` starts being relevant — never shared across phases).

## Trajectory

Every phase and every diagnose attempt appends to the walker's `trajectory` list. At end of run it's written as `trajectory.jsonl` alongside the repo — an ordered log of what happened, what failed, and how it was repaired.

Record shape:

```
{
  "phase": "endpoints",
  "attempt": 2,
  "outcome": "pass" | "fail" | "capped",
  "gate": "jac check",
  "diagnostics": [...],
  "duration_ms": 12345
}
```

Two uses:

1. **Analytics** — which phase fails most, which cap gets hit, which diagnostic codes dominate. This is how the pipeline gets tuned.
2. **Training signal** — the (state, diagnostic, fix) triples are useful for teaching self-correction.

## Skill injection

Skills come from `jac guide --export ./skills/` at pipeline-init time. The pipeline does not bundle its own copy — the CLI is the source of truth and stays aligned.

Every LLM phase's prompt has this shape:

1. **Stable prefix** (identical bytes across every phase and every attempt within a phase): system prompt (which tells the model where `./skills/` lives and to read from it when unsure of syntax or patterns), `jac-core-cheatsheet`, `jac-project-kinds`, repo tour.
2. **Preloaded phase skills** (from the node table above) — the ones the model *definitely* needs, injected so it doesn't pay a file-read round-trip for them. `jac-debugging` is preloaded **unconditionally** as part of a gated phase's own skill set (not added dynamically only once a repair is needed) — that keeps the prefix through part 2 byte-identical across a phase's first attempt and every later retry, which is what makes `llama-server`'s KV-cache reuse actually hold within a phase, not just across phases.
3. **Phase task** (composed from the walker's state — for a retry, this is the diagnose round's repair instruction, built from the gate's failing output).
4. **On-demand skills** — everything else in `./skills/`, not injected. The model reads them mid-phase via its file tool if it decides it needs them.

Prefix stability is what makes `llama-server`'s KV-cache reuse work across phases; the preload list per phase is fixed, so the prefix through part 2 is byte-stable within a phase. On-demand reads happen after that boundary and don't invalidate the cached prefix.

## Headless agent invocation

Factory drives Claude Code non-interactively (`claude -p`), which raises two operational questions worth answering explicitly:

**What stops it from hanging on a permission prompt?** Interactively, Claude Code pauses for approval before risky tool calls (editing files, running shell commands) — exactly the actions every LLM phase needs to take. A headless call that blocks on a prompt no one can answer would hang the pipeline forever. Factory invokes `claude -p` with `--dangerously-skip-permissions`. This is safe here specifically because every phase operates inside a repo Factory itself scaffolded moments earlier into a throwaway destination path — there's nothing pre-existing to damage, no network access is needed beyond the local Unsloth server, and nothing the model does inside that repo is trusted anyway until `jac check`/`jac test`/the smoke assertions say so afterward. (The CLI's own help text recommends this flag "only for sandboxes with no internet access" — a freshly scaffolded, locally-gated build directory is exactly that.)

**How does the orchestrator know it's time to advance?** Never by asking the model. `claude -p` returning just means the agent stopped taking turns — necessary, but Factory never treats "the agent said it's done" as sufficient. Every phase node, after `claude -p` exits, runs its own gate command (`jac check`, `jac test`, or the smoke curl sequence) itself and reads its exit code. Advancing to the next node depends only on that exit code, never on the model's claim. This is "Gates are ground truth" applied literally to the model/orchestrator boundary, not just to phase transitions.

## Output buckets

Nothing is thrown away. The routing rule is drawn in the graph above — `Harvest` → marketplace, `DiagnoseModel` capping → archived, any other `Diagnose` node capping → repaircenter. Each bucket, shape `{repo/, spec/, trajectory.jsonl, meta.json}`:

- **`marketplace/`** — clean SFT data.
- **`repaircenter/`** — awaiting repair; still an "almost got it" RL signal.
- **`refurbished/`** — was `repaircenter/`, Repair-pipeline got it green. Tagged in `meta.json` so it stays distinguishable from marketplace-originals.
- **`archived/`** — terminal, never retried.

Factory writes only `marketplace/`/`repaircenter/`/`archived/`. Repair writes only `refurbished/`/`archived/`. A project only ever moves buckets via a deliberate Repair action.

## Model server

One local model, one server, many clients.

Unsloth Studio is run persistently and exposes an OpenAI + Anthropic compatible API on `localhost:8888` (`/v1/chat/completions`, `/v1/messages`, `/v1/responses`, `/v1/models`), authed via `Authorization: Bearer $UNSLOTH_STUDIO_AUTH_TOKEN`. Every client the pipeline uses points at that same server:

- **Coding agent (Claude Code):** Factory runs `unsloth start claude --no-launch` once at startup, which prints the exact env vars (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, plus a few `CLAUDE_CODE_*` tuning vars) needed to point plain `claude -p` calls at the running server. Factory captures those once and reuses them as the environment for every subsequent `claude -p` subprocess call it makes — it does not re-invoke `unsloth start claude` per phase.
- **byllm calls from Jac orchestrator code (Customer):** provider config points at `http://localhost:8888/v1` with the same token.
- **Ad-hoc HTTP:** anything else (analytics, curl, tests) hits the same endpoint.

No session collision, no restart between callers — the server handles concurrent requests. The Studio process is the pipeline's model dependency; when it's up, everything routes.

## v1 guardrails

Constraints the phase system prompt states up front and the gates enforce:

- **No JSX, no npm imports, no React.** `--kind service` has no client target; any JSX/npm import will fail placement at `jac check`. When it does slip through, the Diagnose node reaches for `jac-codespaces` on-demand to help the model understand the diagnostic and rewrite as pure Jac.
- **Prefer pure Jac over Python interop.** Python is available via `jac-python-interop` but should be reached for only when Jac stdlib genuinely can't do the thing. Uniformity of output matters for training-data quality.

## What byllm is *not* used for

byllm is not an FSM controller. It does not decide which phase runs next, when a gate has passed, or which bucket a sample lands in. The model reading `./skills/<name>/SKILL.md` mid-phase via its file tool is *not* byllm-driven — it's the model using its own file-read tool inside a phase whose control flow is still owned by the FSM. If we ever want deterministic per-run *preload* selection, the hook is a `skills_hint: [...]` field in the spec, decided once by Customer.

"""Factory: spec -> gated build -> bucket. Scaffold + Design + Model + Endpoints + Tests + Smoke + Harvest, each gated phase with its own Diagnose loop."""

import from pathlib { Path }
import os;
import subprocess;
import time;
import uuid;
import sys;
import shutil;
import json;
import re;
import yaml;
import socket;
import from urllib { request as urlreq }
import from urllib.error { HTTPError }


glob FACTORY_DIR: str = str(Path(__file__ or ".").parent.resolve());
glob SKILLS_DIR: str = str(Path(FACTORY_DIR) / "skills");
glob WORK_ROOT: str = str(Path(FACTORY_DIR) / ".work");
glob OUTPUT_DIR: str = str(Path(FACTORY_DIR) / "output");
glob SPECS_DIR: str = str(Path(FACTORY_DIR).parent / "customer" / "specs");

glob MODEL_SKILLS: list[str] = ["jac-node-edge-patterns"];
glob ENDPOINTS_SKILLS: list[str] = ["jac-sv-endpoints"];
glob TESTS_SKILLS: list[str] = [];   # inlined below — jac-testing stays in the on-demand menu
glob SMOKE_SKILLS: list[str] = ["jac-sv-endpoints"];

glob SMOKE_HOST: str = "127.0.0.1";
glob SMOKE_PORT: int = 8123;
glob SMOKE_READY_TIMEOUT_S: int = 30;
glob SMOKE_CALL_TIMEOUT_S: int = 10;

glob JAC_PG_DIR: str = str(Path.home() / ".cache" / "jac" / "pg" / "main");
glob JAC_PG_DIST: str = str(Path.home() / ".cache" / "jac" / "pg" / "dist");

glob GATE_CAP: int = 5;
glob GLOBAL_CAP: int = 20;


# ---------- gate runner ----------

obj GateResult {
    has passed: bool;
    has output: str;
    has exit_code: int;
    has duration_ms: int;
}

def run_gate(cmd: list[str], cwd: str) -> GateResult {
    t0 = time.time();
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True);
    elapsed_ms = int((time.time() - t0) * 1000);
    combined = (result.stdout or "") + (result.stderr or "");
    return GateResult(
        passed=(result.returncode == 0),
        output=combined,
        exit_code=result.returncode,
        duration_ms=elapsed_ms,
    );
}


# ---------- claude -p wrapper ----------

obj ToolTrace {
    # Per-tool aggregates for one `claude -p` invocation. Counts and total wall-clock
    # duration per bucket. assistant_ms is time spent NOT waiting on any tool call —
    # i.e. the model generating tokens (or thinking, if the model supports it).
    has counts: dict[str, int] = {};
    has durations_ms: dict[str, int] = {};
    has assistant_ms: int = 0;
}

obj ClaudeResult {
    has stdout: str;
    has stderr: str;
    has exit_code: int;
    has duration_ms: int;
    has trace: ToolTrace = ToolTrace();
}

def bucket_tool(name: str, input_val: any) -> str {
    # Split Bash calls by what jac subcommand they invoke — that's the phase-boundary
    # signal we actually care about (grammar-fixing loop vs test-run vs anything else).
    if name == "Bash" and isinstance(input_val, dict) {
        cmd_any: any = input_val.get("command");
        cmd: str = cmd_any if isinstance(cmd_any, str) else "";
        if "jac check" in cmd { return "Bash(jac_check)"; }
        if "jac test" in cmd { return "Bash(jac_test)"; }
        if "jac run" in cmd { return "Bash(jac_run)"; }
        if "jac start" in cmd { return "Bash(jac_start)"; }
        return "Bash(other)";
    }
    return name;
}

def summarize_trace(t: ToolTrace) -> str {
    # Compact one-line-per-bucket summary for terminal output.
    parts: list[str] = [f"assistant={t.assistant_ms/1000:.1f}s"];
    for k in sorted(t.counts.keys()) {
        c = t.counts[k];
        ms = t.durations_ms.get(k, 0);
        parts.append(f"{k}={c}×{ms/1000:.1f}s");
    }
    return " | ".join(parts);
}

def trace_to_dict(t: ToolTrace) -> dict[str, any] {
    return {
        "assistant_ms": t.assistant_ms,
        "counts": dict(t.counts),
        "durations_ms": dict(t.durations_ms),
    };
}

def capture_claude_env -> dict[str, str] {
    result = subprocess.run(
        ["unsloth", "start", "claude", "--no-launch"],
        capture_output=True, text=True
    );
    env: dict[str, str] = dict(os.environ);
    for line in (result.stdout or "").splitlines() {
        stripped = line.strip();
        if stripped.startswith("export ") {
            parts = stripped[len("export "):].split("=", 1);
            if len(parts) == 2 {
                env[parts[0].strip()] = parts[1].strip();
            }
        } elif stripped.startswith("unset ") {
            env.pop(stripped[len("unset "):].strip(), None);
        }
    }
    # --bare mode strictly reads ANTHROPIC_API_KEY (not AUTH_TOKEN). Unsloth
    # sets AUTH_TOKEN; copy it across so both spellings work downstream.
    if "ANTHROPIC_AUTH_TOKEN" in env and "ANTHROPIC_API_KEY" not in env {
        env["ANTHROPIC_API_KEY"] = env["ANTHROPIC_AUTH_TOKEN"];
    }
    return env;
}

def claude_headless(
    prompt: str,
    cwd: str,
    session_id: str,
    resume: bool,
    env: dict[str, str],
) -> ClaudeResult {
    # stream-json gives us per-event visibility into the sub-agent's tool calls,
    # so we can attribute wall-clock time to Read/Write/Bash(jac_check)/etc. instead
    # of guessing what the model spent 300+ seconds on. --verbose is required for
    # stream-json to actually stream instead of buffering the whole run.
    cmd: list[str] = [
        "claude", "-p", prompt,
        "--bare",
        "--dangerously-skip-permissions",
        "--exclude-dynamic-system-prompt-sections",
        "--output-format", "stream-json",
        "--verbose",
    ];
    if resume {
        cmd.extend(["--resume", session_id]);
    } else {
        cmd.extend(["--session-id", session_id]);
    }
    t0 = time.time();
    proc = subprocess.Popen(
        cmd, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    );

    trace = ToolTrace();
    pending: dict[str, dict[str, any]] = {};   # tool_use_id -> {"bucket": str, "start": float}
    last_event_time: float = t0;
    final_text: str = "";

    stdout_stream: any = proc.stdout;
    for line in stdout_stream {
        stripped: str = line.strip();
        if not stripped { continue; }
        now = time.time();
        ev: any = None;
        try {
            ev = json.loads(stripped);
        } except Exception {
            continue;
        }
        if not isinstance(ev, dict) { continue; }
        etype_any: any = ev.get("type");
        etype: str = etype_any if isinstance(etype_any, str) else "";

        # Attribute the wall time since the last event: if no tools are in flight,
        # the model was generating; otherwise it's tool-execution time (already
        # counted per-tool when the result event lands).
        dt_ms = int((now - last_event_time) * 1000);
        if not pending {
            trace.assistant_ms += dt_ms;
        }

        if etype == "assistant" {
            msg_any: any = ev.get("message");
            msg: dict[str, any] = msg_any if isinstance(msg_any, dict) else {};
            content_any: any = msg.get("content");
            content: list[any] = content_any if isinstance(content_any, list) else [];
            for block in content {
                if isinstance(block, dict) and block.get("type") == "tool_use" {
                    tid_any: any = block.get("id");
                    tname_any: any = block.get("name");
                    tinput: any = block.get("input");
                    if isinstance(tid_any, str) and isinstance(tname_any, str) {
                        bucket_name: str = bucket_tool(tname_any, tinput);
                        pending[tid_any] = {"bucket": bucket_name, "start": now};
                    }
                }
            }
        } elif etype == "user" {
            msg_any = ev.get("message");
            msg = msg_any if isinstance(msg_any, dict) else {};
            content_any = msg.get("content");
            content = content_any if isinstance(content_any, list) else [];
            for block in content {
                if isinstance(block, dict) and block.get("type") == "tool_result" {
                    tid_any = block.get("tool_use_id");
                    if isinstance(tid_any, str) and tid_any in pending {
                        rec: dict[str, any] = pending.pop(tid_any);
                        bucket_str: str = rec["bucket"];
                        start_t: float = rec["start"];
                        dur_ms: int = int((now - start_t) * 1000);
                        trace.counts[bucket_str] = trace.counts.get(bucket_str, 0) + 1;
                        trace.durations_ms[bucket_str] = trace.durations_ms.get(bucket_str, 0) + dur_ms;
                    }
                }
            }
        } elif etype == "result" {
            res_any: any = ev.get("result");
            if isinstance(res_any, str) { final_text = res_any; }
        }

        last_event_time = now;
    }

    comm_result: any = proc.communicate();
    stderr_any: any = comm_result[1];
    stderr_txt: str = stderr_any if isinstance(stderr_any, str) else "";
    elapsed_ms = int((time.time() - t0) * 1000);
    return ClaudeResult(
        stdout=final_text,
        stderr=stderr_txt,
        exit_code=proc.returncode,
        duration_ms=elapsed_ms,
        trace=trace,
    );
}


# ---------- prompt composer ----------

def read_skill(name: str) -> str {
    path = Path(SKILLS_DIR) / name / "SKILL.md";
    if path.exists() {
        return path.read_text();
    }
    return "";
}

def skills_menu(exclude: list[str]) -> str {
    # One-line skill menu (name + first sentence of description) so the model
    # knows what else is available for on-demand reads. Skills already in the
    # preloaded set aren't listed — pointless to advertise what's already above.
    excluded = set(exclude);
    lines: list[str] = [];
    skills_root = Path(SKILLS_DIR);
    if not skills_root.exists() {
        return "";
    }
    for entry in sorted(skills_root.iterdir()) {
        if entry.name in excluded {
            continue;
        }
        skill_md = entry / "SKILL.md";
        if not skill_md.exists() {
            continue;
        }
        desc = "";
        for line in skill_md.read_text().splitlines()[:20] {
            stripped = line.strip();
            if stripped.startswith("description:") {
                full = stripped[len("description:"):].strip();
                # First sentence only — the topic. Rest is usage hints
                # (Load when..., Pair with...) that a coding model doesn't need.
                first_stop = full.find(". ");
                desc = full[:first_stop] if first_stop > 0 else full;
                break;
            }
        }
        lines.append(f"- {entry.name}: {desc}");
    }
    return "\n".join(lines);
}

def compose_prompt(phase_skills: list[str], task: str) -> str {
    # Skills dir sits at factory/skills/; sub-agents run from factory/.work/<name>/,
    # so the relative path is ../../skills/<name>/SKILL.md.
    preloaded = ["jac-core-cheatsheet", "jac-project-kinds"] + phase_skills;
    menu = skills_menu(preloaded);
    parts: list[str] = [
        "You are working inside a scaffolded Jac project. Skills already loaded into this prompt: ",
        ", ".join(preloaded),
        ". More Jac skill files live at `../../skills/<name>/SKILL.md` — read them via your file tools when you need deeper detail than what's loaded:\n\n",
        menu,
        "\n\n--- jac-core-cheatsheet ---\n",
        read_skill("jac-core-cheatsheet"),
        "\n\n--- jac-project-kinds ---\n",
        read_skill("jac-project-kinds"),
    ];
    for skill in phase_skills {
        parts.extend([f"\n\n--- {skill} ---\n", read_skill(skill)]);
    }
    parts.extend(["\n\n--- Task ---\n", task]);
    return "".join(parts);
}


# ---------- trajectory & bucket routing ----------

def persist_trajectory(work_dir: str, trajectory: list[dict[str, any]]) {
    # Overwrite <work_dir>/.factory/trajectory.jsonl atomically-ish (one line per record).
    factory_dir = Path(work_dir) / ".factory";
    factory_dir.mkdir(parents=True, exist_ok=True);
    with open(str(factory_dir / "trajectory.jsonl"), "w") as f {
        for entry in trajectory {
            f.write(json.dumps(entry) + "\n");
        }
    }
}

def model_tag(env: dict[str, str]) -> str {
    # Short human-readable identifier for the code model that produced this sample.
    # Directory names use this as `<tag>_<spec_name>` so runs from different models
    # don't collide in the same bucket. Priority: explicit MODEL_TAG override →
    # first hyphen-segment of ANTHROPIC_MODEL's last path part, capitalized →
    # "Unknown". e.g. `unsloth/gemma-4-12B-it-qat-GGUF` → `Gemma`,
    # `qwen/Qwen3-30B-A3B-Coder-Instruct` → `Qwen3`. Set MODEL_TAG when you want
    # a specific label instead.
    explicit_any: any = env.get("MODEL_TAG");
    if isinstance(explicit_any, str) and explicit_any {
        return explicit_any;
    }
    model_any: any = env.get("ANTHROPIC_MODEL");
    model: str = model_any if isinstance(model_any, str) else "";
    if not model {
        return "Unknown";
    }
    first = model.split("/")[-1].split("-")[0];
    return first.capitalize() if first else "Unknown";
}

def route_to_bucket(work_dir: str, spec_name: str, bucket: str, reason: str, env: dict[str, str]) -> str {
    # Finalize .factory/meta.json, then move the whole work dir into the bucket.
    # Bucket entries are named `<model_tag>_<spec_name>` so parallel dataset
    # runs with different code models (Gemma / Qwen3 / Sonnet / ...) can share
    # one bucket dir without stepping on each other.
    tag = model_tag(env);
    factory_dir = Path(work_dir) / ".factory";
    factory_dir.mkdir(parents=True, exist_ok=True);
    meta = {
        "spec_name": spec_name,
        "bucket": bucket,
        "reason": reason,
        "model": env.get("ANTHROPIC_MODEL", "unknown"),
        "model_tag": tag,
    };
    (factory_dir / "meta.json").write_text(json.dumps(meta, indent=2));

    tagged = f"{tag}_{spec_name}";
    dest = Path(OUTPUT_DIR) / bucket / tagged;
    if dest.exists() {
        shutil.rmtree(str(dest));
    }
    dest.parent.mkdir(parents=True, exist_ok=True);
    shutil.move(work_dir, str(dest));
    print(f"[route] {tagged} -> {bucket} ({reason})");
    return str(dest);
}


# ---------- task builders ----------

def design_task(spec_requirement_md: str, spec_smoke_yaml: str) -> str {
    return f"""You are Factory's Design phase. The spec below describes a small backend project in framework-agnostic terms; produce a Jac-specific IMPLEMENTATION PLAN detailed enough that the Model and Endpoints phases can just transcribe it — no design decisions left for them to make.

Write THREE files into the CURRENT DIRECTORY (use your Write tool):

## 1. `pipeline.md` — the detailed Jac plan.

Structure it exactly like this (use these section headers verbatim):

```
# <Project name>

## Overview

```mermaid
graph LR
    <ShowTheNodeEdgeShape>
```

One short paragraph on how data flows through the graph.

## Data model

### node <NodeName>
- has <field>: <jac_type>  [= <default>]
- has <field>: <jac_type>
- ...

### edge <EdgeName>: <FromNode> --> <ToNode>
- (no fields)   OR   - has <field>: <jac_type>

...one section per node and edge...

## Endpoints

### <capability_name>  —  walker:pub  |  def:pub
- inputs: <name>: <jac_type>, ...
- output: <report shape for walker, return type for function>
- flow:
    1. <first step in Jac terms — e.g. "look up target = jobj(self.project_id); disengage if not TimeEntry">
    2. <next step>
    3. ...
- touches: <which node/edge types this endpoint reads or writes>

...one block per capability...

## Traversal notes (optional)

Any tricky patterns worth calling out — e.g. "list_time_entries starts from Project via jobj(project_id), then visits [-->[?:TimeEntry]] to gather".
```

Rules:
- Use exact Jac types: `str`, `int`, `float`, `bool`, `datetime` (from `datetime`), `date`, `list[T]`. Do NOT use the spec's noun vocabulary (`string`, `list of X`, etc.) — that's for the customer-facing spec, not the Jac plan.
- The spec's `id` type means Jac's built-in `jid` — do NOT declare an `id` field on any node; Jac auto-generates one.
- Walker vs function: walkers TRAVERSE the graph (visit nodes, call `report`); functions are pure operations with no traversal. Match the spec's `Jac form:` annotation for each capability — if the annotation is missing, decide based on whether the operation reads/writes graph state (walker) vs pure compute (function).
- Every capability from the spec's Endpoints section MUST appear in the plan, no more no less.

## 2. `requirement.md` — Jac-annotated copy of the input requirement.md.

Same structure and prose, but add a `Jac form: walker` or `Jac form: function` line at the top of every endpoint block. Keep the framework-agnostic capability vocabulary otherwise.

## 3. `README.md` — short human-readable project description.

Overwrites the scaffold's stub. One paragraph on what the project does, plus a bulleted capability list.

Do NOT write any Jac source code — that's for the Model and Endpoints phases. Do not touch any existing `.jac` files.

--- input: requirement.md ---
{spec_requirement_md}

--- input: smoke.yaml ---
{spec_smoke_yaml}
""";
}

def design_gate_check(work_dir: str) -> GateResult {
    t0 = time.time();
    w = Path(work_dir);
    files = {
        "pipeline.md": w / "pipeline.md",
        "requirement.md": w / "requirement.md",
        "README.md": w / "README.md",
    };
    problems: list[str] = [];
    for (name, p) in files.items() {
        if not p.exists() {
            problems.append(f"missing: {name}");
        }
    }
    if files["pipeline.md"].exists() {
        content = files["pipeline.md"].read_text();
        if "```mermaid" not in content {
            problems.append("pipeline.md missing ```mermaid block");
        }
        if "## Data model" not in content {
            problems.append("pipeline.md missing '## Data model' section");
        }
        if "## Endpoints" not in content {
            problems.append("pipeline.md missing '## Endpoints' section");
        }
    }
    elapsed_ms = int((time.time() - t0) * 1000);
    return GateResult(
        passed=(len(problems) == 0),
        output=("; ".join(problems) if problems else "design artifacts ok"),
        exit_code=(0 if not problems else 1),
        duration_ms=elapsed_ms,
    );
}

def scaffold_gate_check(work_dir: str) -> GateResult {
    t0 = time.time();
    jac_toml = Path(work_dir) / "jac.toml";
    elapsed_ms = int((time.time() - t0) * 1000);
    if jac_toml.exists() {
        return GateResult(passed=True, output=f"jac.toml at {jac_toml}", exit_code=0, duration_ms=elapsed_ms);
    }
    return GateResult(passed=False, output=f"jac.toml not found at {jac_toml}", exit_code=1, duration_ms=elapsed_ms);
}

def model_task_first -> str {
    return """You are Factory's Model phase. Read `pipeline.md` at the root of this repo — that's the detailed Jac plan Design produced. Your job is to translate its `## Data model` section into actual `node` and `edge` declarations. This is transcription, not design; every field type and default is already decided.

Deliverables:
- Create `model.jac` (at the repo root, NOT in a subdirectory) with each `node` and `edge` archetype from pipeline.md's Data model section, exactly matching its field lists, types, and defaults.
- Import `datetime` if any field uses it: `import from datetime { datetime }`.
- Do NOT add fields not in the Data model section. Do NOT add walkers, endpoints, or `with entry` blocks — those come next phase.
- Leave `main.jac` alone; the scaffold stub gets replaced by the Endpoints phase.

CRITICAL: **NEVER add an `id` field**, even if the spec mentions `id`. Jac gives every node a built-in `jid` automatically — an explicit `id` field is drift from the plan and will cause id-collision bugs downstream. If pipeline.md ever lists `has id: ...`, ignore that line.

Gate: `jac check -e .` — everything must type-check. If a diagnostic is confusing, read `../../skills/jac-debugging/SKILL.md`.
""";
}

def pipeline_declared_types(work_dir: str) -> list[str] {
    # Parse pipeline.md's ### node/### edge headers.
    p = Path(work_dir) / "pipeline.md";
    if not p.exists() {
        return [];
    }
    types: list[str] = [];
    for line in p.read_text().splitlines() {
        stripped = line.strip();
        if stripped.startswith("### node ") {
            name = stripped[len("### node "):].strip().split()[0];
            types.append(name);
        } elif stripped.startswith("### edge ") {
            # "### edge HasTimeEntry: Project --> TimeEntry"
            rest = stripped[len("### edge "):].strip();
            types.append(rest.split(":")[0].strip().split()[0]);
        }
    }
    return types;
}

def code_declared_types(work_dir: str) -> list[str] {
    # Scan every .jac SOURCE file at the repo root — skip the .jac/ build-cache
    # directory which also matches "*.jac".
    types: list[str] = [];
    for jac_file in Path(work_dir).glob("*.jac") {
        if not jac_file.is_file() {
            continue;
        }
        content = jac_file.read_text();
        for match in re.finditer(r"\b(?:node|edge)\s+(\w+)\s*[{:;]", content) {
            types.append(match.group(1));
        }
    }
    return types;
}

# Types that ship in the `jac create --kind service` scaffold. Not project drift.
glob SCAFFOLD_TYPES: list[str] = ["Message"];

def model_plan_drift(work_dir: str) -> str {
    # Returns "" if the code's declared types match the plan, else a message.
    planned = set(pipeline_declared_types(work_dir));
    declared = set(code_declared_types(work_dir));
    extras = declared - planned - set(SCAFFOLD_TYPES);
    if not extras {
        return "";
    }
    return f"model.jac declares node/edge types that are NOT in pipeline.md's '## Data model' section: {sorted(extras)}. These are drift from the plan — remove them. Only implement what pipeline.md lists.";
}

def model_repair_task(failure_output: str) -> str {
    return f"""Your last change didn't pass `jac check`. Diagnostics:

```
{failure_output[:8000]}
```

Fix these issues in the existing files. Don't restart from scratch — repair what's broken. The goal is still just the DATA MODEL (nodes/edges + has fields); no walkers, no endpoints yet.

Read `./skills/jac-debugging/SKILL.md` for how to interpret the diagnostic codes (E-codes and W-codes).
""";
}

def spec_uses_byllm(work_dir: str) -> bool {
    req = Path(work_dir) / "requirement.md";
    if not req.exists() {
        return False;
    }
    return "uses_byllm: true" in req.read_text().lower();
}

def endpoints_task_first(uses_byllm: bool) -> str {
    byllm_note = "";
    if uses_byllm {
        byllm_note = "\n\nNOTE: This project's spec has `uses_byllm: true` — at least one capability should be powered by an LLM call via `def name(...) -> T by llm(...)`. Read `../../skills/jac-by-llm/SKILL.md` for the `by llm(...)` + `sem` mechanics.";
    }
    return f"""You are Factory's Endpoints phase. The data model (nodes/edges) is already in place in `model.jac`. The detailed plan is in `pipeline.md` — read both, then implement each endpoint from pipeline.md's `## Endpoints` section EXACTLY per its `inputs`, `output`, and `flow` spec. This is transcription, not design.

Node IDs (important — don't invent your own scheme):
- Every node has an auto-generated string id retrieved via the builtin `jid(node)` function (NOT `node.jid`) — call `jid(some_node)` to get the id string to return/report.
- To look up a node by id, use `jobj(id_str)` — returns the node or `None`.
- Endpoints that take a `project_id: str` param should call `jobj(project_id)` and check `if project is None {{ ... }}` before use.

Deliverables:
- For each endpoint marked `walker:pub`: declare `walker:pub <name>` with its listed inputs as `has` fields, and translate its numbered `flow:` steps into `can <ability> with <NodeType> entry {{ ... }}` abilities (typically one `entry` ability doing the traversal, plus `entry` handlers for each visited node type).
- For each endpoint marked `def:pub`: declare `def:pub <name>(<params>) -> <ReturnType>` implementing the flow.
- Import node/edge types from model.jac: `import from model {{ Project, TimeEntry }}` — do NOT re-declare them.
- Replace the scaffold's stub `main.jac` content. Put endpoints there directly, or in a separate `endpoints.jac` and import it — whichever's cleaner.
- Do NOT write tests, do NOT write throwaway debug/probe files — that's the next phase.

Gate: `jac check -e .` — everything must type-check. Reference (read on demand as needed): `../../skills/jac-walker-patterns/SKILL.md`, `../../skills/jac-sv-persistence/SKILL.md`, `../../skills/jac-debugging/SKILL.md`.{byllm_note}
""";
}

def endpoints_repair_task(failure_output: str) -> str {
    return f"""Your endpoint changes didn't pass `jac check`. Diagnostics:

```
{failure_output[:8000]}
```

Fix these in place. Don't restart. The goal remains: every capability from requirement.md implemented as a walker or function per its `Jac form:` annotation, and the whole repo type-checks.

Read `./skills/jac-debugging/SKILL.md` for how to interpret the diagnostic codes.
""";
}

def discover_test_files(work_dir: str) -> list[str] {
    # Any .jac SOURCE file at the repo root whose name contains "test".
    # We pass these explicitly to `jac test` so the model isn't locked into
    # pytest-jaclang's `test_*.jac` discovery pattern — any of `test_all.jac`,
    # `all_tests.jac`, `tests.jac`, `endpoint_tests.jac` is fine.
    out: list[str] = [];
    for f in sorted(Path(work_dir).glob("*.jac")) {
        if not f.is_file() { continue; }
        if "test" in f.name.lower() {
            out.append(f.name);
        }
    }
    return out;
}

def tests_task_first -> str {
    return """You are Factory's Tests phase. The endpoints are implemented in main.jac (imports from model.jac). Read `requirement.md` for the `## Test scenarios` section and the endpoint list, plus `pipeline.md` for the detailed signatures.

Write tests using Jac's `test "name" { ... }` block form. Put them in ONE file at the repo root — the filename must contain the word "test" (e.g. `tests.jac`, `test_all.jac`, or `all_tests.jac` all work). Do NOT scatter probes across many files. Every scenario listed in requirement.md's Test scenarios section must be covered.

Test-block skeleton (this is all the syntax you need):
```jac
import from main { create_project, list_projects }
import from model { Project }

test "creates a project" {
    w = root spawn create_project(name="alpha");
    assert len(w.reports) == 1;
    assert w.reports[0].name == "alpha";
}
```

Node IDs (important):
- Every node has an auto-generated id — get it with the builtin `jid(node)` function (NOT `node.jid`). Look up a node by id with `jobj(id_str)`.
- Endpoints that RETURN a node give you back the whole node — grab `jid(returned)` if you need the id for a follow-up call.
- Walker endpoints put results in `.reports` after `spawn`; e.g. `w = root spawn ListProjects(); id = jid(w.reports[0]);`.

Deliverables:
- Import endpoints and node types: `import from main { create_project, list_projects, ... }` and `import from model { Project, TimeEntry }`.
- For each walker endpoint: `w = root spawn WalkerName(...); assert len(w.reports) == 1;` etc.
- For each function endpoint: call directly, inspect the return value.
- Use `assert` — a failing assert fails the test.
- Do NOT modify main.jac / model.jac / any non-test file. Do NOT write throwaway debug/probe files.

Gate: Factory runs `jac test <your_test_filename.jac>` — an EXPLICIT filename, not `jac test .`. Verify your work with the exact same shape: `jac test <the_file_you_wrote>`. **Do NOT try `jac test .` (whole-directory discovery) and do NOT investigate pytest collection behavior** — Factory bypasses that path entirely by passing the filename. As soon as `jac test <filename>` shows `passed` for every test, you're done — stop, don't add "one final verification" rounds.

Reference (read on demand only if a diagnostic is confusing): `../../skills/jac-testing/SKILL.md`, `../../skills/jac-debugging/SKILL.md`.
""";
}

def tests_repair_task(failure_output: str) -> str {
    return f"""`jac test` didn't pass. Output:

```
{failure_output[:8000]}
```

Fix in place. Don't rewrite from scratch. Symmetrically consider both possibilities — the bug may be in the TEST (wrong expectation, wrong setup) or in the ENDPOINT (missing side effect, wrong return shape, missing edge attachment). Look at BOTH the failing test AND the endpoint it calls before deciding which to edit.

Heuristic — when the failure signal is:
- `AssertionError` on `len(collection) == N` where N > 0 and got 0 → almost always a missing side effect in the endpoint (e.g. a walker created a node but never attached it via an edge, so a follow-up traversal can't reach it). Fix the endpoint.
- `AssertionError` on a specific value mismatch → could be either; read the endpoint's flow in `pipeline.md` and see what it's supposed to return.
- `AttributeError` / `NoneType has no attribute X` → usually endpoint returned nothing or wrong type; fix the endpoint's return path.
- Compilation error (`E-code`) → grammar bug in test or endpoint; fix wherever the error line is.
- `no tests ran` → filename discovery issue; rename the test file so it contains "test". (This applies to `jac test <filename>` failing to find tests INSIDE the file. Factory does NOT run `jac test .` — do not try to make whole-directory discovery work.)

Don't just soften the assertion to make it pass — the assertions encode the spec's acceptance criteria.

Reference (read on demand): `../../skills/jac-testing/SKILL.md`, `../../skills/jac-debugging/SKILL.md`, `../../skills/jac-sv-endpoints/SKILL.md`, `../../skills/jac-sv-persistence/SKILL.md`.
""";
}


# ---------- smoke helpers ----------

obj SmokeResult {
    has passed: bool;
    has output: str;
    has duration_ms: int;
}

def detect_endpoint_kinds(work_dir: str) -> dict[str, str] {
    # Scan .jac source files at repo root for `walker:pub <name>` and `def:pub <name>`.
    # Returns {name: "walker"|"function"}. Ground truth for what got implemented.
    kinds: dict[str, str] = {};
    for jac_file in Path(work_dir).glob("*.jac") {
        if not jac_file.is_file() { continue; }
        content = jac_file.read_text();
        for m in re.finditer(r"\bwalker\s*:\s*pub\s+(\w+)", content) {
            kinds[m.group(1)] = "walker";
        }
        for m in re.finditer(r"\bdef\s*:\s*pub\s+(\w+)", content) {
            kinds[m.group(1)] = "function";
        }
    }
    return kinds;
}

def wait_for_port(host: str, port: int, timeout_s: int) -> bool {
    deadline = time.time() + timeout_s;
    while time.time() < deadline {
        try {
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
            s.settimeout(0.5);
            s.connect((host, port));
            s.close();
            return True;
        } except OSError {
            time.sleep(0.2);
        }
    }
    return False;
}

def start_service(work_dir: str, port: int, env: dict[str, str]) -> any {
    return subprocess.Popen(
        ["jac", "start", "main.jac", "--host", SMOKE_HOST, "--port", str(port)],
        cwd=work_dir, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    );
}

def _pg_bin(name: str) -> str {
    # Locate a shipped postgres binary (psql, pg_ctl, ...) under ~/.cache/jac/pg/dist/.
    dist = Path(JAC_PG_DIST);
    if not dist.exists() { return ""; }
    for sub in sorted(dist.iterdir()) {
        candidate = sub / "bin" / name;
        if candidate.exists() { return str(candidate); }
    }
    return "";
}

def _project_db_name(work_dir: str) -> str {
    # Mirror jaclang.runtimelib.session.project_db_name for the sub-project's
    # `jac start main.jac` invocation. base_path = work_dir, target = main.jac,
    # so the derived db is `jac_main_<sha1(abspath(work_dir))[:8]>`.
    import hashlib;
    abs_path = str(Path(work_dir).resolve()).encode("utf-8");
    digest = hashlib.sha1(abs_path).hexdigest()[:8];
    return f"jac_main_{digest}";
}

def _find_pg_socket_dir -> str {
    # Embedded pg listens on a unix socket at /tmp/jacpg-<hash>/; the exact
    # dir is passed via `unix_socket_directories=` when postgres starts.
    # If pg isn't running yet there's no socket to find, which is fine — the
    # first-smoke case starts with no leftover data anyway.
    r = subprocess.run(
        ["pgrep", "-af", f"postgres -D {JAC_PG_DIR}"],
        capture_output=True, text=True,
    );
    for line in (r.stdout or "").splitlines() {
        m = re.search(r"unix_socket_directories=(\S+)", line);
        if m {
            return m.group(1).strip("'\"");
        }
    }
    return "";
}

def wipe_project_db(work_dir: str) -> None {
    # Drop just the sub-project's database on the shared embedded pg cluster,
    # instead of wiping the whole cluster's data dir (which would sever
    # Factory's own walker-state connection — Factory persists into the same
    # cluster under a DIFFERENT database, `jac_main_<hash-of-factory-cwd>`).
    # Safe no-op if pg isn't running or psql isn't available.
    sock_dir = _find_pg_socket_dir();
    if not sock_dir { return; }
    psql = _pg_bin("psql");
    if not psql { return; }
    db_name = _project_db_name(work_dir);
    # WITH (FORCE) terminates lingering connections; needs pg 13+, which the
    # embedded 18 comfortably satisfies. Connect via unix socket, superuser
    # `jac`, admin db `postgres`.
    subprocess.run(
        [psql, "-h", sock_dir, "-U", "jac", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
         "-c", f"DROP DATABASE IF EXISTS {db_name} WITH (FORCE);"],
        capture_output=True,
    );
}

def stop_service(proc: any) {
    proc.terminate();
    try {
        proc.wait(timeout=3);
    } except Exception {
        proc.kill();
    }
}

def substitute_input(input_val: any, captures: dict[str, str]) -> any {
    # Whole-string ${var} substitution only. No partial interpolation.
    if isinstance(input_val, str) {
        if input_val.startswith("${") and input_val.endswith("}") {
            key = input_val[2:-1];
            if key in captures {
                return captures[key];
            }
        }
        return input_val;
    } elif isinstance(input_val, dict) {
        out: dict[str, any] = {};
        for (k, v) in input_val.items() {
            out[k] = substitute_input(v, captures);
        }
        return out;
    } elif isinstance(input_val, list) {
        return [substitute_input(v, captures) for v in input_val];
    }
    return input_val;
}

def find_unresolved(val: any) -> list[str] {
    out: list[str] = [];
    if isinstance(val, str) {
        if val.startswith("${") and val.endswith("}") {
            out.append(val);
        }
    } elif isinstance(val, dict) {
        for v in val.values() {
            out.extend(find_unresolved(v));
        }
    } elif isinstance(val, list) {
        for v in val {
            out.extend(find_unresolved(v));
        }
    }
    return out;
}

def http_post_json(url: str, body: dict[str, any], timeout_s: int) -> dict[str, any] {
    data = json.dumps(body).encode("utf-8");
    req = urlreq.Request(url, data=data, headers={"Content-Type": "application/json"});
    resp: any = None;
    try {
        resp = urlreq.urlopen(req, timeout=timeout_s);
        raw = resp.read().decode("utf-8");
        parsed: any = raw;
        try { parsed = json.loads(raw); } except Exception { parsed = raw; }
        return {"status": resp.status, "body": parsed, "error": ""};
    } except HTTPError as e {
        raw = "";
        try { raw = e.read().decode("utf-8"); } except Exception { raw = ""; }
        parsed_e: any = raw;
        try { parsed_e = json.loads(raw); } except Exception { parsed_e = raw; }
        return {"status": e.code, "body": parsed_e, "error": f"HTTPError {e.code}"};
    } except Exception as e {
        return {"status": 0, "body": None, "error": f"{type(e).__name__}: {str(e)}"};
    } finally {
        if resp is not None {
            try { resp.close(); } except Exception { _ = None; }
        }
    }
}

def extract_id(response_body: any, kind: str) -> str {
    # Pull the newly-created node's id out of a response so a later step can
    # substitute it. Jac's response envelope is inconsistent:
    #   walker report items serialize with `jid`,
    #   function returns serialize with `_jac_id`.
    # We try all three variants (plus a plain `id` field) to cover both.
    if not isinstance(response_body, dict) { return ""; }
    data = response_body.get("data");
    if not isinstance(data, dict) { return ""; }
    candidate: any = None;
    if kind == "function" {
        candidate = data.get("result");
    } elif kind == "walker" {
        reports = data.get("reports") or [];
        if reports {
            candidate = reports[0];
        }
    }
    if isinstance(candidate, dict) {
        return candidate.get("jid") or candidate.get("_jac_id") or candidate.get("id") or "";
    }
    if isinstance(candidate, str) {
        return candidate;
    }
    return "";
}

def dict_subset_match(candidate: any, expected: dict[str, any]) -> bool {
    if not isinstance(candidate, dict) { return False; }
    for (k, v) in expected.items() {
        if candidate.get(k) != v { return False; }
    }
    return True;
}

def check_assertion(assertion: dict[str, any], response: dict[str, any], kind: str) -> str {
    # "" on pass, human-readable message on fail.
    body = response.get("body");
    if not isinstance(body, dict) {
        return f"response body is not a JSON object: {response.get('error', '(no error)')} raw={body}";
    }
    if "expect_success" in assertion {
        want = assertion["expect_success"];
        got = body.get("ok");
        if got != want {
            return f"expect_success={want} but ok={got}, error={body.get('error')}";
        }
        return "";
    }
    if "expect_error" in assertion {
        want = assertion["expect_error"];
        got = (body.get("ok") is False);
        if got != want {
            return f"expect_error={want} but ok={body.get('ok')}";
        }
        return "";
    }
    data_val: any = body.get("data");
    data: dict[str, any] = data_val if isinstance(data_val, dict) else {};
    result: any = data.get("result");
    reports_val: any = data.get("reports");
    reports: list[any] = reports_val if isinstance(reports_val, list) else [];
    if "expect_output_length" in assertion {
        want = assertion["expect_output_length"];
        got_len: int = -1;
        if kind == "walker" {
            got_len = len(reports);
        } elif isinstance(result, list) {
            result_list: list[any] = result;
            got_len = len(result_list);
        } else {
            return f"expect_output_length={want} but function returned non-list: {result}";
        }
        if got_len != want {
            return f"expect_output_length={want} but got {got_len} (kind={kind})";
        }
        return "";
    }
    if "expect_output_contains" in assertion {
        want = assertion["expect_output_contains"];
        if not isinstance(want, dict) {
            return f"expect_output_contains must be an object, got {type(want).__name__}";
        }
        want_dict: dict[str, any] = want;
        if kind == "walker" {
            for r in reports {
                if dict_subset_match(r, want_dict) { return ""; }
            }
            return f"expect_output_contains: no report matched {want_dict}. reports={reports}";
        }
        if dict_subset_match(result, want_dict) { return ""; }
        return f"expect_output_contains: result did not contain {want_dict}. result={result}";
    }
    if "expect_output" in assertion {
        want = assertion["expect_output"];
        if kind == "walker" {
            if reports == want { return ""; }
            if len(reports) == 1 and reports[0] == want { return ""; }
            return f"expect_output={want} but reports={reports}";
        }
        if result == want { return ""; }
        return f"expect_output={want} but result={result}";
    }
    return f"unknown assertion key(s): {list(assertion.keys())}";
}

def run_smoke_scenarios(
    smoke_yaml_text: str,
    kinds: dict[str, str],
    port: int,
) -> SmokeResult {
    t0 = time.time();
    parsed: any = None;
    try {
        parsed = yaml.safe_load(smoke_yaml_text);
    } except Exception as e {
        return SmokeResult(passed=False, output=f"smoke.yaml parse failed: {str(e)}", duration_ms=int((time.time()-t0)*1000));
    }
    if not isinstance(parsed, dict) {
        return SmokeResult(passed=False, output="smoke.yaml root is not a mapping", duration_ms=int((time.time()-t0)*1000));
    }
    scenarios_val: any = parsed.get("scenarios");
    scenarios: list[any] = scenarios_val if isinstance(scenarios_val, list) else [];
    if not scenarios {
        return SmokeResult(passed=False, output="smoke.yaml has no scenarios", duration_ms=int((time.time()-t0)*1000));
    }
    errors: list[str] = [];
    for (si, scenario) in enumerate(scenarios) {
        scenario_dict: dict[str, any] = scenario if isinstance(scenario, dict) else {};
        sname: str = scenario_dict.get("name", f"scenario_{si}");
        captures: dict[str, str] = {};
        steps_val: any = scenario_dict.get("steps");
        steps: list[any] = steps_val if isinstance(steps_val, list) else [];
        for (pi, step) in enumerate(steps) {
            step_dict: dict[str, any] = step if isinstance(step, dict) else {};
            ep: str = step_dict.get("endpoint", "");
            if not ep {
                errors.append(f"[{sname}] step {pi}: missing 'endpoint' field");
                break;
            }
            kind: str = kinds.get(ep, "");
            if kind == "" {
                errors.append(f"[{sname}] step {pi} ({ep}): endpoint not found in generated repo (looked for walker:pub or def:pub)");
                break;
            }
            raw_input: any = step_dict.get("input");
            if raw_input is None { raw_input = {}; }
            resolved = substitute_input(raw_input, captures);
            unresolved = find_unresolved(resolved);
            if unresolved {
                errors.append(f"[{sname}] step {pi} ({ep}): unresolved captures {unresolved}. Available captures: {list(captures.keys())}");
                break;
            }
            url = f"http://{SMOKE_HOST}:{port}/{kind}/{ep}";
            resolved_dict: dict[str, any] = resolved if isinstance(resolved, dict) else {};
            resp = http_post_json(url, resolved_dict, SMOKE_CALL_TIMEOUT_S);
            if resp.get("error") and resp.get("status") == 0 {
                errors.append(f"[{sname}] step {pi} ({ep} {kind}): transport error: {resp['error']}");
                break;
            }
            asserts_val: any = step_dict.get("assertions");
            asserts: list[any] = asserts_val if isinstance(asserts_val, list) else [];
            step_failed = False;
            for a in asserts {
                assertion_dict: dict[str, any] = a if isinstance(a, dict) else {};
                msg = check_assertion(assertion_dict, resp, kind);
                if msg {
                    errors.append(f"[{sname}] step {pi} ({ep} {kind}): {msg}");
                    step_failed = True;
                    break;
                }
            }
            if step_failed { break; }
            cap: any = step_dict.get("capture");
            if cap {
                cid = extract_id(resp.get("body"), kind);
                if not cid {
                    errors.append(f"[{sname}] step {pi} ({ep} {kind}): capture={cap} requested but no id found. body={resp.get('body')}");
                    break;
                }
                cap_key: str = cap;
                captures[cap_key] = cid;
            }
        }
    }
    duration_ms = int((time.time() - t0) * 1000);
    if errors {
        return SmokeResult(passed=False, output="\n".join(errors), duration_ms=duration_ms);
    }
    return SmokeResult(passed=True, output=f"{len(scenarios)} scenarios passed", duration_ms=duration_ms);
}

def smoke_gate(work_dir: str, smoke_yaml_text: str, env: dict[str, str], port: int) -> SmokeResult {
    # Full gate: wipe sub-project db → detect endpoint kinds → start service →
    # wait for readiness → run scenarios → stop. The wipe MUST come before
    # start_service: Jac persists graph state to the shared embedded pg cluster
    # (`~/.cache/jac/pg/main`), so leftover nodes from prior attempts leak in
    # and make walkers like `list_projects` return the wrong count. We only
    # drop the sub-project's own database — never the whole cluster, which
    # would sever Factory's own walker-state connection and crash the run at
    # the next `visit`.
    t0 = time.time();
    wipe_project_db(work_dir);
    kinds = detect_endpoint_kinds(work_dir);
    kinds_line = "endpoint kinds: " + (", ".join([f"{k}={v}" for (k, v) in kinds.items()]) or "(none detected)");

    proc = start_service(work_dir, port, env);
    ready = wait_for_port(SMOKE_HOST, port, SMOKE_READY_TIMEOUT_S);
    if not ready {
        stop_service(proc);
        tail: str = "";
        try {
            comm: any = proc.communicate(timeout=1);
            out_any: any = comm[0];
            err_any: any = comm[1];
            out_bytes: bytes = out_any if isinstance(out_any, bytes) else b"";
            err_bytes: bytes = err_any if isinstance(err_any, bytes) else b"";
            combined: bytes = out_bytes + err_bytes;
            tail = combined.decode("utf-8", errors="replace")[-1500:];
        } except Exception {
            tail = "";
        }
        return SmokeResult(
            passed=False,
            output=f"{kinds_line}\nservice failed to bind on {SMOKE_HOST}:{port} within {SMOKE_READY_TIMEOUT_S}s\n--- server output tail ---\n{tail}",
            duration_ms=int((time.time()-t0)*1000),
        );
    }
    result = run_smoke_scenarios(smoke_yaml_text, kinds, port);
    stop_service(proc);
    return SmokeResult(
        passed=result.passed,
        output=f"{kinds_line}\n{result.output}",
        duration_ms=int((time.time()-t0)*1000),
    );
}

def smoke_repair_task(failure_output: str) -> str {
    return f"""Smoke tests didn't pass. The service was started via `jac start`, scenarios from `smoke.yaml` were replayed as HTTP calls, and one or more assertions failed. Diagnostics:

```
{failure_output[:8000]}
```

The FIRST LINE of the diagnostic lists every detected endpoint and whether it was routed as walker (`/walker/<name>`) or function (`/function/<name>`). Cross-check that against your implementations in `main.jac` / `model.jac`.

Common causes:
- A walker doesn't `report` the created/looked-up node → `data.reports` is empty → `expect_output_length` and `capture` fail.
- A `def:pub` function returns something that isn't the created node → `expect_output_contains` fails.
- A mutation isn't persisted (edge not created, root not attached) so a follow-up lookup finds nothing.
- Wrong response shape (returning a plain dict instead of a node instance).

Fix in place in the .jac files. The assertions in `smoke.yaml` are the customer's contract — DO NOT edit `smoke.yaml`. The generated code must match the assertions.

Reference (read on demand): `../../skills/jac-sv-endpoints/SKILL.md`, `../../skills/jac-sv-persistence/SKILL.md`, `../../skills/jac-debugging/SKILL.md`.
""";
}


# ---------- graph ----------

node ScaffoldNode {}
node DesignNode {}
node ModelNode {}
node DiagnoseModelNode {}
node EndpointsNode {}
node DiagnoseEndpointsNode {}
node TestsNode {}
node DiagnoseTestsNode {}
node SmokeNode {}
node DiagnoseSmokeNode {}
node HarvestNode {}


walker Factory {
    has spec_name: str = "";

    # Working state, set in begin.
    has work_dir: str = "";
    has spec_requirement_md: str = "";
    has spec_smoke_yaml: str = "";
    has claude_env: dict[str, str] = {};

    # Design failure survives so DiagnoseModel can see it on Model's first repair.
    has design_gate_failure: str = "";

    # Per-phase session state and per-phase-repair timing.
    has model_session_id: str = "";
    has model_last_failure: str = "";
    has model_repair_llm_ms: int = 0;
    has endpoints_session_id: str = "";
    has endpoints_last_failure: str = "";
    has endpoints_repair_llm_ms: int = 0;
    has tests_session_id: str = "";
    has tests_last_failure: str = "";
    has tests_repair_llm_ms: int = 0;
    has smoke_session_id: str = "";
    has smoke_last_failure: str = "";
    has smoke_repair_llm_ms: int = 0;

    # Per-phase trace of the most recent claude -p call: what tools it ran, for
    # how long, how much wall time was model-generation vs tool-execution. Carries
    # from the Diagnose ability into the next phase entry (same as *_repair_llm_ms).
    has model_repair_trace: dict[str, any] = {};
    has endpoints_repair_trace: dict[str, any] = {};
    has tests_repair_trace: dict[str, any] = {};
    has smoke_repair_trace: dict[str, any] = {};

    # phase_attempts is reset when a phase is entered for the first time;
    # total_attempts is run-wide.
    has phase_attempts: int = 0;
    has total_attempts: int = 0;

    has trajectory: list[dict[str, any]] = [];
    has reports: list[str] = [];

    can begin with Root entry {
        spec_dir = Path(SPECS_DIR) / self.spec_name;
        if not spec_dir.exists() {
            print(f"[error] spec not found: {spec_dir}");
            disengage;
        }
        self.spec_requirement_md = (spec_dir / "requirement.md").read_text();
        self.spec_smoke_yaml = (spec_dir / "smoke.yaml").read_text();

        # .work/<name>/ is the run's working dir. Fresh each run. Don't create
        # it here — jac create refuses if the target already exists. Scaffold
        # creates it via `jac create <name> --kind service`, then .factory/
        # gets added afterward for trajectory persistence.
        work_root = Path(WORK_ROOT);
        work_root.mkdir(parents=True, exist_ok=True);
        self.work_dir = str(work_root / self.spec_name);
        if Path(self.work_dir).exists() {
            shutil.rmtree(self.work_dir);
        }

        print(f"[begin] spec={self.spec_name} work_dir={self.work_dir}");
        print("[begin] capturing claude env...");
        self.claude_env = capture_claude_env();

        s = ScaffoldNode();
        d = DesignNode();
        m = ModelNode();
        dm = DiagnoseModelNode();
        e = EndpointsNode();
        de = DiagnoseEndpointsNode();
        t = TestsNode();
        dt = DiagnoseTestsNode();
        sm = SmokeNode();
        ds = DiagnoseSmokeNode();
        h = HarvestNode();
        root ++> s;
        s ++> d;
        d ++> m;
        m ++> dm;
        dm ++> m;
        m ++> e;
        e ++> de;
        de ++> e;
        e ++> t;
        t ++> dt;
        dt ++> t;
        t ++> sm;
        sm ++> ds;
        ds ++> sm;
        sm ++> h;
        visit s;
    }

    can on_scaffold with ScaffoldNode entry {
        # `jac create <name> --kind service` inside .work/ nests silently (per
        # jac-scaffold skill), producing .work/<name>/{jac.toml, main.jac, ...}.
        # This is why we don't need a repo/ subdir.
        r = run_gate(
            ["jac", "create", self.spec_name, "--kind", "service"],
            WORK_ROOT,
        );
        print(f"[scaffold] jac create exit={r.exit_code} in {r.duration_ms}ms");

        gate = scaffold_gate_check(self.work_dir);
        self.trajectory.append({
            "phase": "scaffold",
            "attempt": 1,
            "outcome": ("pass" if gate.passed else "fail"),
            "gate": "jac.toml exists",
            "llm_ms": 0,
            "gate_ms": r.duration_ms + gate.duration_ms,
            "duration_ms": r.duration_ms + gate.duration_ms,
            "diagnostics": gate.output,
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if not gate.passed {
            print(f"[scaffold] FAIL: {gate.output}");
            route_to_bucket(self.work_dir, self.spec_name, "archived", "scaffold_failed", self.claude_env);
            disengage;
        } else {
            # Isolate git context: git init here so claude sub-agents walking
            # up for `.git` find this repo, not JacProjectFactory's. Set a
            # local user identity too so commits (if any) don't inherit yours.
            subprocess.run(["git", "init", "-q"], cwd=self.work_dir);
            subprocess.run(["git", "config", "user.name", "factory"], cwd=self.work_dir);
            subprocess.run(["git", "config", "user.email", "factory@local"], cwd=self.work_dir);
            visit [here -->];
        }
    }

    can on_design with DesignNode entry {
        task = design_task(self.spec_requirement_md, self.spec_smoke_yaml);
        prompt = compose_prompt(["jac-node-edge-patterns", "jac-sv-endpoints"], task);
        session_id = str(uuid.uuid4());

        print(f"[design] calling claude -p (session={session_id[:8]}...)");
        r = claude_headless(prompt, self.work_dir, session_id, False, self.claude_env);
        print(f"[design] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        print(f"[design] trace: {summarize_trace(r.trace)}");

        gate = design_gate_check(self.work_dir);
        self.trajectory.append({
            "phase": "design",
            "attempt": 1,
            "outcome": ("pass" if gate.passed else "fail"),
            "gate": "design_gate_check",
            "llm_ms": r.duration_ms,
            "gate_ms": gate.duration_ms,
            "duration_ms": r.duration_ms + gate.duration_ms,
            "diagnostics": gate.output,
            "trace": trace_to_dict(r.trace),
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if gate.passed {
            print(f"[design] gate PASS ({gate.output})");
        } else {
            print(f"[design] gate FAIL: {gate.output}");
            self.design_gate_failure = gate.output;
            # Not fatal — DiagnoseModel will surface this on Model's first repair.
        }
        visit [here -->];
    }

    can on_model with ModelNode entry {
        # Fresh session on first entry; on later entries the LLM call already
        # happened in DiagnoseModel and we just re-run the gate.
        llm_ms = 0;
        trace_dict: dict[str, any] = {};
        if self.model_session_id == "" {
            self.model_session_id = str(uuid.uuid4());
            task = model_task_first();
            prompt = compose_prompt(MODEL_SKILLS, task);
            print(f"[model] first attempt: claude -p (session={self.model_session_id[:8]}...)");
            r = claude_headless(prompt, self.work_dir, self.model_session_id, False, self.claude_env);
            print(f"[model] claude -p exit={r.exit_code} in {r.duration_ms}ms");
            print(f"[model] trace: {summarize_trace(r.trace)}");
            llm_ms = r.duration_ms;
            trace_dict = trace_to_dict(r.trace);
        } else {
            llm_ms = self.model_repair_llm_ms;
            trace_dict = self.model_repair_trace;
            self.model_repair_llm_ms = 0;
            self.model_repair_trace = {};
        }

        gate = run_gate(["jac", "check", "-e", "."], self.work_dir);
        self.phase_attempts += 1;
        self.total_attempts += 1;
        self.trajectory.append({
            "phase": "model",
            "attempt": self.phase_attempts,
            "outcome": ("pass" if gate.passed else "fail"),
            "gate": "jac check",
            "llm_ms": llm_ms,
            "gate_ms": gate.duration_ms,
            "duration_ms": llm_ms + gate.duration_ms,
            "diagnostics": gate.output[:8000],
            "trace": trace_dict,
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if gate.passed {
            drift = model_plan_drift(self.work_dir);
            if drift == "" {
                print(f"[model] gate PASS on attempt {self.phase_attempts}");
                visit [here -->[?:EndpointsNode]];
            } else {
                # jac check passed but the code drifted from the plan. Feed the
                # drift message back through DiagnoseModel like any other failure.
                print(f"[model] gate PASS but DRIFT on attempt {self.phase_attempts}: {drift}");
                self.model_last_failure = drift;
                visit [here -->[?:DiagnoseModelNode]];
            }
        } else {
            print(f"[model] gate FAIL on attempt {self.phase_attempts} (total {self.total_attempts})");
            self.model_last_failure = gate.output;
            visit [here -->[?:DiagnoseModelNode]];
        }
    }

    can on_diagnose_model with DiagnoseModelNode entry {
        if self.phase_attempts >= GATE_CAP or self.total_attempts >= GLOBAL_CAP {
            reason = f"model_cap: phase={self.phase_attempts} total={self.total_attempts}";
            print(f"[diagnose_model] CAP HIT — archiving ({reason})");
            route_to_bucket(self.work_dir, self.spec_name, "archived", reason, self.claude_env);
            disengage;
            return;
        }
        task = model_repair_task(self.model_last_failure);
        prompt = compose_prompt(MODEL_SKILLS, task);
        print(f"[diagnose_model] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.model_session_id, True, self.claude_env);
        print(f"[diagnose_model] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        print(f"[diagnose_model] trace: {summarize_trace(r.trace)}");
        if r.exit_code != 0 {
            print(f"[diagnose_model] STDERR: {r.stderr[:500]}");
        }
        self.model_repair_llm_ms = r.duration_ms;
        self.model_repair_trace = trace_to_dict(r.trace);
        visit [here -->[?:ModelNode]];
    }

    can on_endpoints with EndpointsNode entry {
        llm_ms = 0;
        trace_dict: dict[str, any] = {};
        if self.endpoints_session_id == "" {
            # First entry — reset per-phase counter, start fresh session.
            self.phase_attempts = 0;
            self.endpoints_session_id = str(uuid.uuid4());
            uses_byllm = spec_uses_byllm(self.work_dir);
            skills = ENDPOINTS_SKILLS[:];
            if uses_byllm {
                skills.append("jac-by-llm");
            }
            task = endpoints_task_first(uses_byllm);
            prompt = compose_prompt(skills, task);
            print(f"[endpoints] first attempt: claude -p (session={self.endpoints_session_id[:8]}...) uses_byllm={uses_byllm}");
            r = claude_headless(prompt, self.work_dir, self.endpoints_session_id, False, self.claude_env);
            print(f"[endpoints] claude -p exit={r.exit_code} in {r.duration_ms}ms");
            print(f"[endpoints] trace: {summarize_trace(r.trace)}");
            llm_ms = r.duration_ms;
            trace_dict = trace_to_dict(r.trace);
        } else {
            llm_ms = self.endpoints_repair_llm_ms;
            trace_dict = self.endpoints_repair_trace;
            self.endpoints_repair_llm_ms = 0;
            self.endpoints_repair_trace = {};
        }

        gate = run_gate(["jac", "check", "-e", "."], self.work_dir);
        self.phase_attempts += 1;
        self.total_attempts += 1;
        self.trajectory.append({
            "phase": "endpoints",
            "attempt": self.phase_attempts,
            "outcome": ("pass" if gate.passed else "fail"),
            "gate": "jac check",
            "llm_ms": llm_ms,
            "gate_ms": gate.duration_ms,
            "duration_ms": llm_ms + gate.duration_ms,
            "diagnostics": gate.output[:8000],
            "trace": trace_dict,
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if gate.passed {
            print(f"[endpoints] gate PASS on attempt {self.phase_attempts}");
            visit [here -->[?:TestsNode]];
        } else {
            print(f"[endpoints] gate FAIL on attempt {self.phase_attempts} (total {self.total_attempts})");
            self.endpoints_last_failure = gate.output;
            visit [here -->[?:DiagnoseEndpointsNode]];
        }
    }

    can on_diagnose_endpoints with DiagnoseEndpointsNode entry {
        if self.phase_attempts >= GATE_CAP or self.total_attempts >= GLOBAL_CAP {
            reason = f"endpoints_cap: phase={self.phase_attempts} total={self.total_attempts}";
            print(f"[diagnose_endpoints] CAP HIT — routing repaircenter ({reason})");
            route_to_bucket(self.work_dir, self.spec_name, "repaircenter", reason, self.claude_env);
            disengage;
            return;
        }
        uses_byllm = spec_uses_byllm(self.work_dir);
        skills = ENDPOINTS_SKILLS[:];
        if uses_byllm {
            skills = skills + ["jac-by-llm"];
        }
        task = endpoints_repair_task(self.endpoints_last_failure);
        prompt = compose_prompt(skills, task);
        print(f"[diagnose_endpoints] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.endpoints_session_id, True, self.claude_env);
        print(f"[diagnose_endpoints] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        print(f"[diagnose_endpoints] trace: {summarize_trace(r.trace)}");
        if r.exit_code != 0 {
            print(f"[diagnose_endpoints] STDERR: {r.stderr[:500]}");
        }
        self.endpoints_repair_llm_ms = r.duration_ms;
        self.endpoints_repair_trace = trace_to_dict(r.trace);
        visit [here -->[?:EndpointsNode]];
    }

    can on_tests with TestsNode entry {
        llm_ms = 0;
        trace_dict: dict[str, any] = {};
        if self.tests_session_id == "" {
            self.phase_attempts = 0;
            self.tests_session_id = str(uuid.uuid4());
            task = tests_task_first();
            prompt = compose_prompt(TESTS_SKILLS, task);
            print(f"[tests] first attempt: claude -p (session={self.tests_session_id[:8]}...)");
            r = claude_headless(prompt, self.work_dir, self.tests_session_id, False, self.claude_env);
            print(f"[tests] claude -p exit={r.exit_code} in {r.duration_ms}ms");
            print(f"[tests] trace: {summarize_trace(r.trace)}");
            llm_ms = r.duration_ms;
            trace_dict = trace_to_dict(r.trace);
        } else {
            llm_ms = self.tests_repair_llm_ms;
            trace_dict = self.tests_repair_trace;
            self.tests_repair_llm_ms = 0;
            self.tests_repair_trace = {};
        }

        test_files = discover_test_files(self.work_dir);
        if not test_files {
            gate = GateResult(passed=False, output="no test files found: expected a .jac file at the repo root whose name contains 'test' (e.g. tests.jac or test_all.jac)", exit_code=1, duration_ms=0);
        } else {
            gate = run_gate(["jac", "test"] + test_files, self.work_dir);
        }
        self.phase_attempts += 1;
        self.total_attempts += 1;
        self.trajectory.append({
            "phase": "tests",
            "attempt": self.phase_attempts,
            "outcome": ("pass" if gate.passed else "fail"),
            "gate": "jac test",
            "llm_ms": llm_ms,
            "gate_ms": gate.duration_ms,
            "duration_ms": llm_ms + gate.duration_ms,
            "diagnostics": gate.output[:8000],
            "trace": trace_dict,
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if gate.passed {
            print(f"[tests] gate PASS on attempt {self.phase_attempts}");
            visit [here -->[?:SmokeNode]];
        } else {
            print(f"[tests] gate FAIL on attempt {self.phase_attempts} (total {self.total_attempts})");
            self.tests_last_failure = gate.output;
            visit [here -->[?:DiagnoseTestsNode]];
        }
    }

    can on_diagnose_tests with DiagnoseTestsNode entry {
        if self.phase_attempts >= GATE_CAP or self.total_attempts >= GLOBAL_CAP {
            reason = f"tests_cap: phase={self.phase_attempts} total={self.total_attempts}";
            print(f"[diagnose_tests] CAP HIT — routing repaircenter ({reason})");
            route_to_bucket(self.work_dir, self.spec_name, "repaircenter", reason, self.claude_env);
            disengage;
            return;
        }
        task = tests_repair_task(self.tests_last_failure);
        prompt = compose_prompt(TESTS_SKILLS, task);
        print(f"[diagnose_tests] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.tests_session_id, True, self.claude_env);
        print(f"[diagnose_tests] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        print(f"[diagnose_tests] trace: {summarize_trace(r.trace)}");
        if r.exit_code != 0 {
            print(f"[diagnose_tests] STDERR: {r.stderr[:500]}");
        }
        self.tests_repair_llm_ms = r.duration_ms;
        self.tests_repair_trace = trace_to_dict(r.trace);
        visit [here -->[?:TestsNode]];
    }

    can on_smoke with SmokeNode entry {
        # First entry: no LLM — deterministic curl-and-assert against jac start.
        # On repair loops, the LLM call already happened in DiagnoseSmoke; here
        # we just re-run the gate.
        trace_dict: dict[str, any] = {};
        if self.smoke_session_id == "" {
            self.phase_attempts = 0;   # reset for smoke's own cap window
            llm_ms = 0;
        } else {
            llm_ms = self.smoke_repair_llm_ms;
            trace_dict = self.smoke_repair_trace;
            self.smoke_repair_llm_ms = 0;
            self.smoke_repair_trace = {};
        }

        print(f"[smoke] starting service on port {SMOKE_PORT}...");
        result = smoke_gate(self.work_dir, self.spec_smoke_yaml, self.claude_env, SMOKE_PORT);
        self.phase_attempts += 1;
        self.total_attempts += 1;
        self.trajectory.append({
            "phase": "smoke",
            "attempt": self.phase_attempts,
            "outcome": ("pass" if result.passed else "fail"),
            "gate": "smoke scenarios",
            "llm_ms": llm_ms,
            "gate_ms": result.duration_ms,
            "duration_ms": llm_ms + result.duration_ms,
            "diagnostics": result.output[:8000],
            "trace": trace_dict,
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if result.passed {
            print(f"[smoke] gate PASS on attempt {self.phase_attempts}");
            visit [here -->[?:HarvestNode]];
        } else {
            print(f"[smoke] gate FAIL on attempt {self.phase_attempts} (total {self.total_attempts})");
            self.smoke_last_failure = result.output;
            visit [here -->[?:DiagnoseSmokeNode]];
        }
    }

    can on_diagnose_smoke with DiagnoseSmokeNode entry {
        if self.phase_attempts >= GATE_CAP or self.total_attempts >= GLOBAL_CAP {
            reason = f"smoke_cap: phase={self.phase_attempts} total={self.total_attempts}";
            print(f"[diagnose_smoke] CAP HIT — routing repaircenter ({reason})");
            route_to_bucket(self.work_dir, self.spec_name, "repaircenter", reason, self.claude_env);
            disengage;
            return;
        }
        # First repair round starts a fresh session (Smoke had no draft step).
        if self.smoke_session_id == "" {
            self.smoke_session_id = str(uuid.uuid4());
            resume = False;
        } else {
            resume = True;
        }
        task = smoke_repair_task(self.smoke_last_failure);
        prompt = compose_prompt(SMOKE_SKILLS, task);
        print(f"[diagnose_smoke] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.smoke_session_id, resume, self.claude_env);
        print(f"[diagnose_smoke] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        print(f"[diagnose_smoke] trace: {summarize_trace(r.trace)}");
        if r.exit_code != 0 {
            print(f"[diagnose_smoke] STDERR: {r.stderr[:500]}");
        }
        self.smoke_repair_llm_ms = r.duration_ms;
        self.smoke_repair_trace = trace_to_dict(r.trace);
        visit [here -->[?:SmokeNode]];
    }

    can on_harvest with HarvestNode entry {
        print(f"[harvest] all gates passed — routing to marketplace");
        dest = route_to_bucket(self.work_dir, self.spec_name, "marketplace", "all_gates_passed", self.claude_env);
        self.reports.append(dest);
        disengage;
    }
}


# ---------- entry ----------

def print_summary(trajectory: list[dict[str, any]]) {
    print("=== summary ===");
    total_llm = 0;
    total_gate = 0;
    for entry in trajectory {
        phase = entry.get("phase", "?");
        attempt = entry.get("attempt", 0);
        outcome = entry.get("outcome", "?");
        llm = entry.get("llm_ms", 0);
        gate = entry.get("gate_ms", 0);
        total = entry.get("duration_ms", 0);
        total_llm += llm;
        total_gate += gate;
        print(f"  {phase} attempt {attempt}: {outcome}  |  llm={llm/1000:.1f}s  gate={gate/1000:.1f}s  total={total/1000:.1f}s");
    }
    print(f"  ---");
    print(f"  TOTAL: {(total_llm + total_gate)/1000:.1f}s (llm={total_llm/1000:.1f}s, gate={total_gate/1000:.1f}s)");
}


with entry {
    spec_name = "freelance-time-tracker";
    if len(sys.argv) > 1 { spec_name = sys.argv[1]; }
    result = root spawn Factory(spec_name=spec_name);
    print_summary(result.trajectory);
    if result.reports {
        print(f"=== final: {result.reports[0]} ===");
    }
}

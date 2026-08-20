"""Factory: spec -> gated build -> bucket. Scaffold + Design + Model + Diagnose."""

import from pathlib { Path }
import os;
import subprocess;
import time;
import uuid;
import sys;
import shutil;
import json;
import re;


glob FACTORY_DIR: str = str(Path(__file__ or ".").parent.resolve());
glob SKILLS_DIR: str = str(Path(FACTORY_DIR) / "skills");
glob WORK_ROOT: str = str(Path(FACTORY_DIR) / ".work");
glob OUTPUT_DIR: str = str(Path(FACTORY_DIR) / "output");
glob SPECS_DIR: str = str(Path(FACTORY_DIR).parent / "customer" / "specs");

glob MODEL_SKILLS: list[str] = ["jac-node-edge-patterns", "jac-has-fields", "jac-types", "jac-debugging"];
glob ENDPOINTS_SKILLS: list[str] = ["jac-walker-patterns", "jac-sv-endpoints", "jac-sv-persistence", "jac-debugging"];
glob TESTS_SKILLS: list[str] = ["jac-testing", "jac-debugging"];

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

obj ClaudeResult {
    has stdout: str;
    has stderr: str;
    has exit_code: int;
    has duration_ms: int;
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
    cmd: list[str] = [
        "claude", "-p", prompt,
        "--bare",
        "--dangerously-skip-permissions",
        "--output-format", "text",
    ];
    if resume {
        cmd.extend(["--resume", session_id]);
    } else {
        cmd.extend(["--session-id", session_id]);
    }
    t0 = time.time();
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env);
    elapsed_ms = int((time.time() - t0) * 1000);
    return ClaudeResult(
        stdout=(result.stdout or ""),
        stderr=(result.stderr or ""),
        exit_code=result.returncode,
        duration_ms=elapsed_ms,
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

def skills_menu -> str {
    # One-line description per skill (parsed from each SKILL.md's YAML front
    # matter `description:` field). Gives the model a menu without needing to ls.
    lines: list[str] = [];
    skills_root = Path(SKILLS_DIR);
    if not skills_root.exists() {
        return "";
    }
    for entry in sorted(skills_root.iterdir()) {
        skill_md = entry / "SKILL.md";
        if not skill_md.exists() {
            continue;
        }
        desc = "";
        for line in skill_md.read_text().splitlines()[:20] {
            stripped = line.strip();
            if stripped.startswith("description:") {
                desc = stripped[len("description:"):].strip();
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
    menu = skills_menu();
    parts: list[str] = [
        "You are working inside a scaffolded Jac project. Additional Jac skill files (SKILL.md each) live at `../../skills/<name>/SKILL.md` relative to your working directory — read them via your file tools when you need deeper detail than what's already loaded below. Available skills:\n\n",
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

def route_to_bucket(work_dir: str, spec_name: str, bucket: str, reason: str) -> str {
    # Finalize .factory/meta.json, then move the whole work dir into the bucket.
    factory_dir = Path(work_dir) / ".factory";
    factory_dir.mkdir(parents=True, exist_ok=True);
    meta = {
        "spec_name": spec_name,
        "bucket": bucket,
        "reason": reason,
        "model": os.environ.get("ANTHROPIC_MODEL", "unknown"),
    };
    (factory_dir / "meta.json").write_text(json.dumps(meta, indent=2));

    dest = Path(OUTPUT_DIR) / bucket / spec_name;
    if dest.exists() {
        shutil.rmtree(str(dest));
    }
    dest.parent.mkdir(parents=True, exist_ok=True);
    shutil.move(work_dir, str(dest));
    print(f"[route] {spec_name} -> {bucket} ({reason})");
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
- Create `model.jac` with each `node` and `edge` archetype from pipeline.md's Data model section, exactly matching its field lists, types, and defaults.
- Import `datetime` if any field uses it: `import from datetime { datetime }`.
- Do NOT add fields not in the Data model section. Do NOT add walkers, endpoints, or `with entry` blocks — those come next phase.
- Leave `main.jac` alone; the scaffold stub gets replaced by the Endpoints phase.

Gate: `jac check .` — everything must type-check. If a diagnostic is confusing, read `../../skills/jac-debugging/SKILL.md`.
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
{failure_output[-4000:]}
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

Deliverables:
- For each endpoint marked `walker:pub`: declare `walker:pub <name>` with its listed inputs as `has` fields, and translate its numbered `flow:` steps into `can <ability> with <NodeType> entry {{ ... }}` abilities (typically one `entry` ability doing the traversal, plus `entry` handlers for each visited node type).
- For each endpoint marked `def:pub`: declare `def:pub <name>(<params>) -> <ReturnType>` implementing the flow.
- Import node/edge types from model.jac: `import from model {{ Project, TimeEntry }}` — do NOT re-declare them.
- Replace the scaffold's stub `main.jac` content. Put endpoints there directly, or in a separate `endpoints.jac` and import it — whichever's cleaner.
- Do NOT write tests — that's the next phase.

Gate: `jac check .` — everything must type-check. Reference: `../../skills/jac-walker-patterns/SKILL.md`, `../../skills/jac-sv-endpoints/SKILL.md`, `../../skills/jac-sv-persistence/SKILL.md`.{byllm_note}
""";
}

def endpoints_repair_task(failure_output: str) -> str {
    return f"""Your endpoint changes didn't pass `jac check`. Diagnostics:

```
{failure_output[-4000:]}
```

Fix these in place. Don't restart. The goal remains: every capability from requirement.md implemented as a walker or function per its `Jac form:` annotation, and the whole repo type-checks.

Read `./skills/jac-debugging/SKILL.md` for how to interpret the diagnostic codes.
""";
}

def tests_task_first -> str {
    return """You are Factory's Tests phase. The endpoints are implemented (main.jac / endpoints.jac). Read `requirement.md` for the `## Test scenarios` section and the endpoint list, plus `pipeline.md` for the detailed signatures.

Write tests using Jac's `test "name" { ... }` block form, one file at the repo root or split under a `tests/` directory — whichever `jac test` picks up. Every scenario listed in requirement.md's Test scenarios section must be covered.

Deliverables:
- Import the endpoints and node types you're testing.
- For each walker endpoint: spawn it on `root`, inspect its `.reports` list.
- For each function endpoint: call it directly, inspect the return value.
- Use `assert` statements — a failing assert fails the test.
- Do NOT touch main.jac / model.jac / any file outside your test files.

Gate: `jac test .` — every test must pass. Read `../../skills/jac-testing/SKILL.md` for the test-block form, `spawn` conventions, and how to write assertions.
""";
}

def tests_repair_task(failure_output: str) -> str {
    return f"""`jac test .` didn't pass. Output:

```
{failure_output[-4000:]}
```

Fix these in place. Don't rewrite from scratch. If a test is failing because of a bug in the tested code (not the test), you may edit the endpoints — but prefer fixing the test if it was written against a wrong expectation.

Read `../../skills/jac-testing/SKILL.md` for reference and `../../skills/jac-debugging/SKILL.md` for interpreting jac diagnostic codes.
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
            route_to_bucket(self.work_dir, self.spec_name, "archived", "scaffold_failed");
            disengage;
        }
        visit [here -->];
    }

    can on_design with DesignNode entry {
        task = design_task(self.spec_requirement_md, self.spec_smoke_yaml);
        prompt = compose_prompt(["jac-node-edge-patterns", "jac-sv-endpoints"], task);
        session_id = str(uuid.uuid4());

        print(f"[design] calling claude -p (session={session_id[:8]}...)");
        r = claude_headless(prompt, self.work_dir, session_id, False, self.claude_env);
        print(f"[design] claude -p exit={r.exit_code} in {r.duration_ms}ms");

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
        if self.model_session_id == "" {
            self.model_session_id = str(uuid.uuid4());
            task = model_task_first();
            prompt = compose_prompt(MODEL_SKILLS, task);
            print(f"[model] first attempt: claude -p (session={self.model_session_id[:8]}...)");
            r = claude_headless(prompt, self.work_dir, self.model_session_id, False, self.claude_env);
            print(f"[model] claude -p exit={r.exit_code} in {r.duration_ms}ms");
            llm_ms = r.duration_ms;
        } else {
            llm_ms = self.model_repair_llm_ms;
            self.model_repair_llm_ms = 0;
        }

        gate = run_gate(["jac", "check", "."], self.work_dir);
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
            "diagnostics": gate.output[:4000],
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
            route_to_bucket(self.work_dir, self.spec_name, "archived", reason);
            disengage;
            return;
        }
        task = model_repair_task(self.model_last_failure);
        prompt = compose_prompt(MODEL_SKILLS, task);
        print(f"[diagnose_model] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.model_session_id, True, self.claude_env);
        print(f"[diagnose_model] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        self.model_repair_llm_ms = r.duration_ms;
        visit [here -->[?:ModelNode]];
    }

    can on_endpoints with EndpointsNode entry {
        llm_ms = 0;
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
            llm_ms = r.duration_ms;
        } else {
            llm_ms = self.endpoints_repair_llm_ms;
            self.endpoints_repair_llm_ms = 0;
        }

        gate = run_gate(["jac", "check", "."], self.work_dir);
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
            "diagnostics": gate.output[:4000],
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
            route_to_bucket(self.work_dir, self.spec_name, "repaircenter", reason);
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
        self.endpoints_repair_llm_ms = r.duration_ms;
        visit [here -->[?:EndpointsNode]];
    }

    can on_tests with TestsNode entry {
        llm_ms = 0;
        if self.tests_session_id == "" {
            self.phase_attempts = 0;
            self.tests_session_id = str(uuid.uuid4());
            task = tests_task_first();
            prompt = compose_prompt(TESTS_SKILLS, task);
            print(f"[tests] first attempt: claude -p (session={self.tests_session_id[:8]}...)");
            r = claude_headless(prompt, self.work_dir, self.tests_session_id, False, self.claude_env);
            print(f"[tests] claude -p exit={r.exit_code} in {r.duration_ms}ms");
            llm_ms = r.duration_ms;
        } else {
            llm_ms = self.tests_repair_llm_ms;
            self.tests_repair_llm_ms = 0;
        }

        gate = run_gate(["jac", "test", "."], self.work_dir);
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
            "diagnostics": gate.output[:4000],
        });
        persist_trajectory(self.work_dir, self.trajectory);

        if gate.passed {
            print(f"[tests] gate PASS on attempt {self.phase_attempts}");
            # Smoke + Harvest not wired yet. Leave in .work/.
            self.reports.append(self.work_dir);
            disengage;
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
            route_to_bucket(self.work_dir, self.spec_name, "repaircenter", reason);
            disengage;
            return;
        }
        task = tests_repair_task(self.tests_last_failure);
        prompt = compose_prompt(TESTS_SKILLS, task);
        print(f"[diagnose_tests] repair round (phase={self.phase_attempts}, total={self.total_attempts})");
        r = claude_headless(prompt, self.work_dir, self.tests_session_id, True, self.claude_env);
        print(f"[diagnose_tests] claude -p exit={r.exit_code} in {r.duration_ms}ms");
        self.tests_repair_llm_ms = r.duration_ms;
        visit [here -->[?:TestsNode]];
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

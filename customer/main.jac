"""Customer: persona -> wish -> spec, emitted to specs/<name>/."""

import from jaclang.byllm.lib { Model }
import from pathlib { Path }
import os;
import json;
import random;
import sys;


glob CUSTOMER_DIR: str = str(Path(__file__ or ".").parent.resolve());

# Unsloth Studio (OpenAI-compatible). Configurable via env for portability.
glob llm: Model = Model(
    model_name=os.environ.get("CUSTOMER_MODEL", "openai/default"),
    api_base=os.environ.get("UNSLOTH_STUDIO_URL", "http://localhost:8888/v1"),
    api_key=os.environ.get("UNSLOTH_STUDIO_AUTH_TOKEN", "dummy"),
);


# ---------- data ----------

obj PersonaSeed {
    has id: str;
    has title: str;
    has background: str;
}

# Phase markers only - no data lives on nodes. The walker carries the run's
# state (see PIPELINE.md); nodes just give the FSM a traversable shape.
node PersonaNode {}
node WishNode {}
node SpecNode {}
node EmitNode {}


# ---------- LLM functions ----------

def draft_wish(persona_title: str, persona_background: str, complexity: str) -> str by llm(temperature=0.8);

sem draft_wish = "Write a first-person, natural-language description of the web app this persona wants. A paragraph or two, in their own voice. No technical schema, no endpoint names. Just what they want to be able to do, and why. Match the given complexity ceiling as a soft upper bound.";
sem draft_wish.persona_title = "A short label naming the persona.";
sem draft_wish.persona_background = "Prose sketch of the persona's context.";
sem draft_wish.complexity = "'tiny', 'small', or 'medium' - a soft upper bound on ambition.";


obj DraftedSpec {
    has project_name: str;
    has requirement_md: str;
    has smoke_yaml: str;
}

sem DraftedSpec.project_name = "Short kebab-case slug for the project (e.g. grad-student-paper-library). Lowercase, hyphens only.";
sem DraftedSpec.requirement_md = "Full content of requirement.md. YAML front matter with keys: name, description, persona, complexity, uses_byllm, non_goals. Then Markdown body with three sections: Data model (entities and relationships), Endpoints (one block each), Test scenarios. Endpoint blocks have: name (verb-based capability like create_paper or search_by_tag), purpose, inputs (typed fields), output (shape), behavior (one paragraph), acceptance criteria. NO HTTP methods, NO URL paths, NO REST vocabulary - the spec is framework-agnostic (do not write things like 'POST /papers' or 'GET /papers/search?q='; endpoints are named capabilities only, e.g. 'create_paper'). Every field type MUST be written as one of these exact lowercase nouns: string, integer, number, boolean, timestamp, date, id, object, or 'list of <noun>' for collections (e.g. 'list of string', 'list of tag'). These are the ONLY valid type words. NEVER write a programming-language type name - not 'str', 'int', 'String', 'Integer', 'Boolean', 'Bool', 'Float', 'UUID', 'DateTime', 'List[...]', or any capitalized/language-specific type. Example - WRONG: 'id: UUID', 'title: String', 'tags: List[String]'. RIGHT: 'id: id', 'title: string', 'tags: list of string'.";
sem DraftedSpec.smoke_yaml = "Full content of smoke.yaml. A top-level `scenarios:` list. Each scenario has a name and a `steps:` list. Each step has: endpoint (name matching one from requirement.md), input (an object), and one or more assertions from this fixed vocabulary: expect_success (bool), expect_error (bool), expect_output (any value the payload equals), expect_output_contains (object of fields to match), expect_output_length (int for list-payload length). NO method or path fields.";

def draft_spec(persona_id: str, wish_text: str, complexity: str) -> DraftedSpec by llm(temperature=0.3);

sem draft_spec = "Turn a persona's wish into a framework-agnostic spec: what entities exist, what capabilities the app exposes, and how to verify them. Describe capabilities by name and purpose, not by HTTP method or path - Factory decides how each capability is exposed. Complexity is a soft ceiling; simpler is fine when the wish is naturally minimal.";
sem draft_spec.persona_id = "The persona seed id, for provenance in the front-matter.";
sem draft_spec.wish_text = "The persona's wish, in their own words.";
sem draft_spec.complexity = "'tiny', 'small', or 'medium'.";


# ---------- walker ----------

walker Customer {
    has complexity: str = "small";
    has seed_id: str = "";
    has out_root: str = "specs";
    has reports: list[str] = [];

    # Run state, carried by the walker across phases (see PIPELINE.md).
    # `persona` is always overwritten in `begin` before any other ability
    # reads it - the FSM is a straight line, so no Optional/None handling.
    has persona: PersonaSeed = PersonaSeed(id="", title="", background="");
    has wish_text: str = "";
    has project_name: str = "";
    has requirement_md: str = "";
    has smoke_yaml: str = "";

    can begin with Root entry {
        seeds_path = Path(CUSTOMER_DIR) / "personas" / "seeds.json";
        raw = json.loads(seeds_path.read_text());
        seeds = [PersonaSeed(id=s["id"], title=s["title"], background=s["background"]) for s in raw];

        chosen: PersonaSeed = random.choice(seeds);
        if self.seed_id != "" {
            matches = [s for s in seeds if s.id == self.seed_id];
            if not matches {
                print(f"[error] no seed with id={self.seed_id}");
                disengage;
            }
            chosen = matches[0];
        }
        self.persona = chosen;

        p = PersonaNode();
        w = WishNode();
        s_node = SpecNode();
        e = EmitNode();
        root ++> p;
        p ++> w;
        w ++> s_node;
        s_node ++> e;
        visit p;
    }

    can on_persona with PersonaNode entry {
        print(f"[persona] using {self.persona.id}");
        visit [here -->];
    }

    can on_wish with WishNode entry {
        self.wish_text = draft_wish(self.persona.title, self.persona.background, self.complexity);
        print(f"[wish] drafted ({len(self.wish_text)} chars)");
        visit [here -->];
    }

    can on_spec with SpecNode entry {
        drafted = draft_spec(self.persona.id, self.wish_text, self.complexity);
        self.project_name = drafted.project_name;
        self.requirement_md = drafted.requirement_md;
        self.smoke_yaml = drafted.smoke_yaml;
        print(f"[spec] drafted; name={self.project_name}");
        visit [here -->];
    }

    can on_emit with EmitNode entry {
        base = Path(self.out_root);
        out_dir = base / self.project_name;
        n = 2;
        while out_dir.exists() {
            out_dir = base / f"{self.project_name}-{n}";
            n += 1;
        }
        out_dir.mkdir(parents=True, exist_ok=True);

        (out_dir / "wish.md").write_text(self.wish_text);
        (out_dir / "requirement.md").write_text(self.requirement_md);
        (out_dir / "smoke.yaml").write_text(self.smoke_yaml);
        meta = {
            "persona": self.persona.id,
            "complexity_ceiling": self.complexity,
            "model": os.environ.get("CUSTOMER_MODEL", "openai/default"),
        };
        (out_dir / "meta.json").write_text(json.dumps(meta, indent=2));

        print(f"[emit] wrote {out_dir}");
        report str(out_dir);
    }
}


# ---------- entry ----------

with entry {
    complexity = "small";
    seed_id = "";
    if len(sys.argv) > 1 { complexity = sys.argv[1]; }
    if len(sys.argv) > 2 { seed_id = sys.argv[2]; }
    result = root spawn Customer(complexity=complexity, seed_id=seed_id);
    if result.reports {
        print(f"done -> {result.reports[0]}");
    }
}

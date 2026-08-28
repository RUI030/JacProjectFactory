"""Freelance time tracker — headless API service.

Projects and time entries are the only two archetypes. They live on the shared
guest `root`; each time entry links back to its owning project through the
`project_id` reference (a plain `jid`). There is no client UI and no typed edge
archetype — every endpoint is a `def:pub` function (the shape rule: no `visit`
means a function, not a walker). The endpoints create, list, and update these
nodes over the reference read `[root -->][?:Type]`.
"""

import from datetime { datetime }
import from model { Project, TimeEntry }


# --- LLM-powered capability --------------------------------------------------

# Generate a short, professional client-facing name for a project. This powers
# the `client_name` fallback in `create_project` (the spec's `uses_byllm: true`).
# The return type is `str`, so it is never retried on malformed output.
def:pub client_name_for(name: str) -> str by llm(temperature=0.2, max_tokens=64);

sem client_name_for = "Generate a short, professional client-facing name for a freelance project.";
sem client_name_for.name = "The project's name.";


# --- Projects ----------------------------------------------------------------

def:pub create_project(name: str, client_name: str = "") -> Project {
    # When the caller omits client_name, synthesize one from the name via the
    # LLM above; otherwise honor the explicit value.
    display_name = client_name if client_name != "" else client_name_for(name);
    return root ++> Project(name=name, client_name=display_name);
}

def:pub list_projects -> list[Project] {
    return [root-->][?:Project];
}


# --- Time entries ------------------------------------------------------------

def:pub start_timer(project_id: jid) -> TimeEntry {
    return root ++> TimeEntry(project_id=project_id, start_time=datetime.now());
}

def:pub stop_timer(entry_id: jid) -> TimeEntry | None {
    for e in [root-->][?:TimeEntry] {
        if jid(e) == entry_id {
            e.end_time = datetime.now();
            end_dt: datetime = e.end_time as datetime;
            start_dt: datetime = e.start_time as datetime;
            e.duration_minutes = round((end_dt - start_dt).total_seconds() / 60);
            return e;
        }
    }
    return None;
}

def:pub list_time_entries(project_id: jid) -> list[TimeEntry] {
    return [
        e
        for e in [root-->][?:TimeEntry]
        if e.project_id == project_id
    ];
}

def:pub mark_as_paid(entry_id: jid) -> TimeEntry | None {
    for e in [root-->][?:TimeEntry] {
        if jid(e) == entry_id {
            e.is_paid = True;
            return e;
        }
    }
    return None;
}

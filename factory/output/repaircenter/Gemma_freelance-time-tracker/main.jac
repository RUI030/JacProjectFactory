import from model { Project, TimeEntry }
import from datetime { datetime as DT }

def:pub create_project(name: str, client_name: str) -> Project {
    return root ++> Project(name=name, client_name=client_name, status="active");
}

walker:pub list_projects {
    can run with Root entry {
        for p in [root -->][?:Project] {
            report p;
        }
    }
}

def:pub start_timer(project_id: str) -> TimeEntry | None {
    project = jobj(project_id);
    if project is None {
        return None;
    }

    now: DT = DT.now();
    # Connect the Project to the TimeEntry via ProjectHasEntry.
    entry: TimeEntry = (project ++> TimeEntry(
        start_time=now,
        end_time=None,
        duration_minutes=0,
        note="Started timer",
        is_paid=False
    )) as TimeEntry;

    return entry;
}

def:pub stop_timer(entry_id: str) -> TimeEntry | None {
    entry = jobj(entry_id);
    if entry is None {
        return None;
    }

    now: DT = DT.now();
    entry = entry as TimeEntry;

    entry.end_time = now;

    # Calculate the duration in minutes.
    # Subtracting two datetime objects in Jac (mapped to Python's datetime)
    # returns a timedelta object.
    duration = now - entry.start_time;

    # Convert timedelta to total minutes.
    # We use total_seconds() to get the duration in seconds and divide by 60.
    entry.duration_minutes = int(duration.total_seconds() / 60);

    return entry;
}

walker:pub list_time_entries {
    has project_id: str;

    can fetch with Project entry {
        # This is visited if a Project is traversed.
    }

    can find_project with Root entry {
        project = jobj(self.project_id);
        if project is None {
            return;
        }
        # "Visit all TimeEntry nodes connected via ProjectHasEntry"
        for entry in [project -->][?:TimeEntry] {
            report entry;
        }
    }
}

def:pub mark_as_paid(entry_id: str) -> TimeEntry | None {
    entry = jobj(entry_id);
    if entry is None {
        return None;
    }

    entry = entry as TimeEntry;
    entry.is_paid = True;
    return entry;
}


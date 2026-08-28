import from main {
    create_project,
    list_projects,
    start_timer,
    stop_timer,
    list_time_entries,
    mark_as_paid
}

import from model {
    Project,
    TimeEntry
}

test "Create a project and list it" {
    project = create_project(name="Project Alpha", client_name="Client A");
    assert project is not None;
    assert project.name == "Project Alpha";
    assert project.client_name == "Client A";

    results = root spawn list_projects();
    assert len(results.reports) >= 1;
    assert results.reports[0].name == "Project Alpha";
}

test "Start a timer, stop it, and view the entry" {
    project = create_project(name="Project Beta", client_name="Client B");
    project_id = jid(project);

    entry = start_timer(project_id);
    assert entry is not None;
    assert entry.start_time is not None;
    assert entry.end_time is None;
    assert entry.is_paid == False;
    entry_id = jid(entry);

    stopped_entry = stop_timer(entry_id);
    assert stopped_entry is not None;
    assert stopped_entry.end_time is not None;
    assert stopped_entry.end_time != entry.start_time;

    results = root spawn list_time_entries(project_id=project_id);
    assert len(results.reports) >= 1;
    assert results.reports[0].start_time == entry.start_time;
}

test "Mark a time entry as paid" {
    project = create_project(name="Project Gamma", client_name="Client C");
    project_id = jid(project);

    entry = start_timer(project_id);
    assert entry is not None;
    entry_id = jid(entry);

    paid_entry = mark_as_paid(entry_id);
    assert paid_entry is not None;
    assert paid_entry.is_paid == True;
}

import from main { create_project, list_projects, start_timer, stop_timer, list_time_entries, mark_as_paid }
import from model { Project, TimeEntry }
import from time { sleep }


test "create a project and list it" {
    p = create_project(name="Acme Website", client_name="Acme Corp");
    assert p is not None;
    assert jid(p) is not None;
    assert p.name == "Acme Website";
    assert p.client_name == "Acme Corp";
    assert p.status == "new";

    projects = list_projects();
    assert projects is not None;
    assert len(projects) == 1;
    assert projects[0] is p;
}


test "explicit client_name is honored" {
    p = create_project(name="Widget Beta", client_name="Beta Labs");
    assert p.client_name == "Beta Labs";
    assert len(list_projects()) == 1;
}


test "start a timer, stop it, and view the entry" {
    p = create_project(name="Probe", client_name="Probe LLC");
    pid = jid(p);

    e = start_timer(pid);
    assert e is not None;
    assert e.project_id == pid;
    assert e.start_time is not None;
    assert e.end_time is None;
    assert e.duration_minutes == 0;

    sleep(61);
    _ = stop_timer(jid(e));

    e = start_timer(pid);
    sleep(61);
    _ = stop_timer(jid(e));

    entries = list_time_entries(pid);
    assert len(entries) == 2;
    assert all(x.project_id == pid for x in entries);
    assert entries[0].duration_minutes >= 1;
    assert entries[1].duration_minutes >= 1;
    assert len(list_time_entries("no-such-project")) == 0;
}


test "mark a time entry as paid" {
    p = create_project(name="Paid Work", client_name="Paid Co");
    pid = jid(p);
    e = start_timer(pid);
    sleep(61);
    _ = stop_timer(jid(e));

    assert e is not None;
    assert not e.is_paid;

    updated = mark_as_paid(jid(e));
    assert updated is not None;
    assert e.is_paid;
    assert updated.is_paid;

    entries = list_time_entries(pid);
    assert len(entries) == 1;
    assert entries[0].is_paid;
    assert entries[0].duration_minutes >= 1;

    _ = mark_as_paid("no-such-entry");
}


test "full lifecycle: create, time, pay, list" {
    p = create_project(name="Full Cycle", client_name="Cycle Inc");
    pid = jid(p);

    e = start_timer(pid);
    sleep(61);
    _ = stop_timer(jid(e));
    _ = mark_as_paid(jid(e));

    assert len(list_projects()) == 1;
    assert list_projects()[0] is p;

    entries = list_time_entries(pid);
    assert len(entries) == 1;
    assert entries[0].is_paid;
    assert entries[0].duration_minutes >= 1;
}

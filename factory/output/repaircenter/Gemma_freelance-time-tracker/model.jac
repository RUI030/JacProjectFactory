import from datetime { datetime as DT }

node Project {
    has name: str;
    has client_name: str;
    has status: str;
}

node TimeEntry {
    has start_time: DT;
    has end_time: DT | None;
    has duration_minutes: int;
    has note: str;
    has is_paid: bool;
}

edge ProjectHasEntry: Project --> TimeEntry {
}

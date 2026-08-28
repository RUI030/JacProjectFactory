import from datetime { datetime }


node Project {
    has name: str;
    has client_name: str = "";
    has status: str = "new";
}


node TimeEntry {
    has project_id: jid | None = None;
    has start_time: datetime | None = None;
    has end_time: datetime | None = None;
    has duration_minutes: int = 0;
    has note: str = "";
    has is_paid: bool = False;
}

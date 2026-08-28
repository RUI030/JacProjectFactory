# Freelance Time Tracker

A lean, keyboard-friendly Jac API service for freelance developers. Track projects,
log billable hours against them, and mark time entries as paid — no team permissions,
no charts, no invoicing. The graph lives on the shared guest `root`; each capability is
a `def:pub` endpoint exposed as an HTTP route (`POST /function/<name>`).

## Capabilities

- **create_project** — create a project (`name`, `client_name`); returns the new `Project`.
- **list_projects** — list every `Project` for a quick status overview.
- **start_timer** — create a `TimeEntry` for a project with the current time as `start_time`.
- **stop_timer** — set `end_time` and compute `duration_minutes` for an entry (found by `entry_id`).
- **list_time_entries** — list a project's `TimeEntry`s (filtered by `project_id`).
- **mark_as_paid** — set `is_paid = true` for an entry (found by `entry_id`).

## Data model

- **Project** — `name`, `client_name` (default `""`), `status` (default `"new"`).
- **TimeEntry** — `project_id` (jid, optional), `start_time`, `end_time`, `duration_minutes`
  (default `0`), `note`, `is_paid` (default `false`). `id` is the auto-generated `jid`.

## Running

```bash
jac start main.jac --no-client   # API only, no frontend bundling
```

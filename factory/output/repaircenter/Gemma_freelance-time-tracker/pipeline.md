# Freelance Time Tracker

## Overview

```mermaid
graph LR
    Project --> TimeEntry
```

The system manages projects and their associated time entries. Projects serve as the primary anchors for work, with time entries linked to them to track billable hours. Data flows from Projects to TimeEntries via a directed relationship.

## Data model

### node Project
- has name: str
- has client_name: str
- has status: str

### node TimeEntry
- has start_time: datetime
- has end_time: datetime | None
- has duration_minutes: int
- has note: str
- has is_paid: bool

### edge ProjectHasEntry: Project --> TimeEntry
- (no fields)

## Endpoints

### create_project —  def:pub
- inputs: name: str, client_name: str
- output: Project
- flow:
    1. Create a new Project node with the provided name and client_name.
    2. Return the new Project.
- touches: Project

### list_projects —  walker:pub
- inputs: none
- output: list[Project]
- flow:
    1. Traverse the graph to find all Project nodes.
    2. Report each Project.
- touches: Project

### start_timer —  def:pub
- inputs: project_id: str
- output: TimeEntry
- flow:
    1. Look up the target Project using jobj(project_id).
    2. Create a new TimeEntry with current timestamp as start_time.
    3. Connect the Project to the TimeEntry via ProjectHasEntry.
    4. Return the TimeEntry.
- touches: Project, TimeEntry, ProjectHasEntry

### stop_timer —  def:pub
- inputs: entry_id: str
- output: TimeEntry
- flow:
    1. Look up the target TimeEntry using jobj(entry_id).
    2. Update the end_time with current timestamp.
    3. Calculate and update duration_minutes.
    4. Return the TimeEntry.
- touches: TimeEntry

### list_time_entries —  walker:pub
- inputs: project_id: str
- output: list[TimeEntry]
- flow:
    1. Look up the target Project using jobj(project_id).
    2. Visit all TimeEntry nodes connected via ProjectHasEntry.
    3. Report each TimeEntry.
- touches: Project, ProjectHasEntry, TimeEntry

### mark_as_paid —  def:pub
- inputs: entry_id: str
- output: TimeEntry
- flow:
    1. Look up the target TimeEntry using jobj(entry_id).
    2. Set is_paid to True.
    3. Return the TimeEntry.
- touches: TimeEntry

## Traversal notes (optional)

`list_time_entries` starts from a Project node (located via `jobj(project_id)`) and then visits all outgoing `TimeEntry` nodes via the `ProjectHasEntry` edge.

---
name: Freelance Time Tracker
description: A lean, keyboard-friendly tool for freelance developers to log billable hours, track project statuses, and manage payments.
persona: freelance-developer
complexity: tiny
uses_byllm: true
non_goals:
  - Team permissions
  - Complex charts or analytics
  - Invoicing generation
  - Multi-user collaboration
---

# Data model (entities and relationships)

- Project:
  - id: id
  - name: string
  - client_name: string
  - status: string

- TimeEntry:
  - id: id
  - project_id: id
  - start_time: timestamp
  - end_time: timestamp
  - duration_minutes: integer
  - note: string
  - is_paid: boolean

# Endpoints

- create_project
  purpose: Create a new project to track work.
  inputs:
    name: string
    client_name: string
  output: object
  behavior: Creates a new project record in the system with the provided name and client name.
  acceptance_criteria: A new project is created and returned with a unique id.

- list_projects
  purpose: Retrieve all projects for a quick status overview.
  inputs: none
  output: list of project
  behavior: Returns a list of all projects currently in the system.
  acceptance_criteria: Returns a list containing all project records.

- start_timer
  purpose: Quickly start a timer for a specific project.
  inputs:
    project_id: id
  output: object
  behavior: Creates a new time entry for the specified project with the current timestamp as the start time and a null end time.
  acceptance_criteria: A new time entry is created for the specified project.

- stop_timer
  purpose: Stop the current timer and log the duration.
  inputs:
    entry_id: id
  output: object
  behavior: Updates the specified time entry with the current timestamp as the end time and calculates the duration in minutes.
  acceptance_criteria: The time entry is updated with an end time and a calculated duration.

- list_time_entries
  purpose: View all time entries for a specific project.
  inputs:
    project_id: id
  output: list of time_entry
  behavior: Returns all time entries associated with the given project ID.
  acceptance_criteria: Returns a list of entries for the specified project.

- mark_as_paid
  purpose: Update a time entry's payment status.
  inputs:
    entry_id: id
  output: object
  behavior: Sets the is_paid flag to true for the specified time entry.
  acceptance_criteria: The entry's is_paid status is updated to true.

# Test scenarios

- Create a project and list it.
- Start a timer, stop it, and view the entry.
- Mark a time entry as paid.
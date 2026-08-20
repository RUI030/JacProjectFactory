---
name: Zebrafish Experiment Logger
description: A simple digital notebook for logging zebrafish behavioral experiments, featuring quick selection of parameters and one-click timestamping.
persona: wet-lab-scientist
complexity: tiny
uses_byllm: false
non_goals:
  - Complex data visualization
  - Automated image analysis
  - Multi-user collaboration
---

## Data model
- Tank: id, name (string)
- Treatment: id, name (string)
- EmbryoStage: id, name (string)
- ExperimentRun: id, timestamp (timestamp), tank_id (id), treatment_id (id), embryo_stage_id (id), notes (string)
- LogEntry: id, run_id (id), event_type (string), timestamp (timestamp)

## Endpoints

name: list_tanks
purpose: Retrieve all available tanks
inputs: {}
output: list of object
behavior: Returns a list of all tanks configured in the system.
acceptance criteria: Returns a non-empty list of tank objects.

name: list_treatments
purpose: Retrieve all available treatments
inputs: {}
output: list of object
behavior: Returns a list of all treatment types.
acceptance criteria: Returns a non-empty list of treatment objects.

name: list_embryo_stages
purpose: Retrieve all available embryo stages
inputs: {}
output: list of object
behavior: Returns a list of all embryo stages.
acceptance criteria: Returns a non-empty list of embryo stage objects.

name: create_experiment_run
purpose: Initialize a new experiment run
inputs:
  tank_id: id
  treatment_id: id
  embryo_stage_id: id
  notes: string
output: object
behavior: Creates a new experiment run record with the specified parameters and current timestamp.
acceptance criteria: Returns a run object with a unique id.

name: record_timestamp
purpose: Quickly log a feeding or imaging event
inputs:
  run_id: id
  event_type: string
output: object
behavior: Records a timestamped entry for a specific event (e.g., 'feeding' or 'imaging') associated with a run.
acceptance criteria: Returns a log entry object with a timestamp.

name: search_runs
purpose: Search for past experiment runs
inputs:
  query: string
output: list of object
behavior: Returns a list of experiment runs matching the query string.
acceptance criteria: Returns a list of run objects.

## Test scenarios
- Create a new run: List tanks, then create a run with a selected tank.
- Record event: Record a feeding event for a specific run.
- Search: Search for runs using a keyword.
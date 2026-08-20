---
name: Grad Student Paper Library
description: A simple tool for researchers to save papers, tag them, and capture personal summaries.
persona: grad-student-paper-library
complexity: tiny
uses_byllm: false
non_goals:
  - Complex citation management
  - PDF parsing
  - Collaborative features
---

## Data model
Paper:
- id: id
- title: string
- author: string
- summary: string
- tags: list of string
- source_url: string
- created_at: timestamp

## Endpoints

save_paper:
purpose: Save a new research paper with metadata and a personal summary.
inputs:
  title: string
  author: string
  summary: string
  tags: list of string
  source_url: string
output: object
behavior: Creates a new paper record in the library and returns the saved object with a generated unique ID and timestamp.
acceptance criteria: Paper is saved successfully and returns the correct data.

list_papers:
purpose: Retrieve all saved papers.
inputs: none
output: list of object
behavior: Returns a list of all papers stored in the library.
acceptance criteria: Returns a list of all papers.

search_papers_by_tag:
purpose: Filter papers by a specific tag.
inputs:
  tag: string
output: list of object
behavior: Returns all papers that contain the specified tag in their tags list.
acceptance criteria: Only papers with the matching tag are returned.

get_paper_details:
purpose: Retrieve details of a specific paper.
inputs:
  id: id
output: object
behavior: Returns the full details of a paper based on its unique ID.
acceptance criteria: Returns the correct paper or an error if not found.

## Test scenarios
1. Save a paper successfully.
2. List all papers.
3. Search for papers with a specific tag.
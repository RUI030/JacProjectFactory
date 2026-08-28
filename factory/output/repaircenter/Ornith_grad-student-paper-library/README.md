# Grad Student Paper Library

A tiny framework-agnostic API service for grad students: save research papers,
tag them, and jot down personal summaries. Researchers create a paper record
with its title, author, summary, tags, and source URL, then browse, search by
tag, or pull up a single paper by its ID. The graph persists all records between
requests; there are no edges — papers are flat records on the shared library
graph.

## Capabilities

- **save_paper** — create a new paper (title, author, summary, tags, source URL);
  the service generates a unique ID and a `created_at` timestamp and returns the
  saved record.
- **list_papers** — list every paper in the library.
- **search_papers_by_tag** — return only the papers whose tag list contains the
  requested tag.
- **get_paper_details** — return the full record for one paper, identified by its
  generated ID (returns an error when the ID is unknown).

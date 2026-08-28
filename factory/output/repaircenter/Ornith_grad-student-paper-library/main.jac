"""API service for the grad student paper library.

A graph-persistent `Paper` node type stored on the shared guest `root`.
Papers are flat records (no edges), so every read is the untyped
`[root -->]` walk narrowed with `[?:Paper]`. The `:pub` walkers and the
`def:pub` function below are the HTTP API the service exposes.
"""

import from datetime { datetime }
import from model { Paper }


def:pub get_paper_details(id: str) -> Paper | None {
    target = jobj(id);
    if isinstance(target, Paper) {
        return target;
    }
    return None;
}


walker:pub save_paper {
    """Create a paper, attach it to the shared root, and report its fields."""
    has title: str,
        author: str,
        summary: str,
        tags: list[str],
        source_url: str;

    can run with Root entry {
        created_at = datetime.now();
        paper = Paper(title=self.title, author=self.author, summary=self.summary, tags=self.tags, source_url=self.source_url, created_at=created_at) as Paper;
        root ++> paper;
        report {"jid": jid(paper), "title": paper.title, "author": paper.author, "summary": paper.summary, "tags": paper.tags, "source_url": paper.source_url, "created_at": paper.created_at};
    }
}


walker:pub list_papers {
    """Report every paper on the shared root."""
    has reports: list[Paper] = [];

    can run with Root entry {
        visit [-->];
    }

    can gather with Paper entry {
        report here;
    }
}


walker:pub search_papers_by_tag {
    """Report the papers whose `tags` list contains the requested tag."""
    has tag: str,
        papers: list[Paper] = [];
    has reports: list[dict[str, list[Paper]]] = [];

    can run with Root entry {
        visit [-->[?:Paper]];
    }

    can gather with Paper entry {
        self.papers.append(here);
    }

    can finish with Root exit {
        filtered = [p for p in self.papers if self.tag in p.tags];
        report {"papers": filtered} as dict[str, list[Paper]];
    }
}

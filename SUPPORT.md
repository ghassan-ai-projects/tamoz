# Support

Tamoz is pre-release software maintained by a small team. This page tells you
how to get the most useful answer with the least back-and-forth.

## Documentation First

Before opening an issue, check whether your question is already answered:

- [README.md](README.md) — what Tamoz is and is not.
- [documentation/getting-started/install.md](documentation/getting-started/install.md) — installation, the CLI surface, and how the agent runs.
- [documentation/operations/operations.md](documentation/operations/operations.md) — running the agent day to day.
- [documentation/limitations.md](documentation/limitations.md) — what does not work yet, and why.

Most questions fall into one of those four pages.

## When To Open An Issue

Open an issue when you have:

- a **reproducible bug** — a concrete command and observed behavior, not a vague symptom;
- a **documentation problem** — a page that is wrong, misleading, or missing something it should cover;
- a **scoped feature request** — a specific, bounded capability, not a general direction;
- an **unanswered compatibility question** — a Ruby version, platform, or dependency combination not covered by the docs.

## What To Include

A good issue includes:

- the **version** you are on (for example `0.1.0.alpha.1`) and how you installed it;
- your **environment** — Ruby version, operating system, and relevant toolchain;
- the **command** you ran, exactly as you ran it;
- the **actual vs expected behavior**;
- any **logs or output** that show the failure — redact credentials and personal data first.

That is enough to reproduce most issues on the first read.

# ADR-009 — Keep model request prefixes stable within a request series

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Partial — settings/catalog identity and history-replacement boundaries need reconciliation
**Relates to:** [ADR-033](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md) (skill instructions also become model request content)

Keep existing request content unchanged as a conversation grows. Append new content, and record a
new request series when the fixed configuration changes or history is compacted.

## Context

Model requests repeatedly include instructions, tool definitions and earlier conversation content.
Keeping that beginning identical lets a provider reuse cached processing when its caching
conditions are met. Accidental changes, such as a different tool order or an added timestamp,
can prevent reuse even when the content means the same thing.

## Decision

Render the fixed request header in a consistent, locale-independent order. Keep system content,
tool definitions, model settings and the skill catalog stable within a request series: consecutive
requests that share the same fixed configuration and extend the same conversation history.

A simplified example shows how a conversation grows (tool-call messages are omitted):

```text
Request 1: instructions + tool definitions + user question
Request 2: instructions + tool definitions + user question + tool result
Request 3: instructions + tool definitions + user question + tool result + follow-up
```

The earlier content stays exactly the same, including ordering and whitespace. New conversation
entries go at the end; a correction is another entry, rather than an edit to an earlier one.

Record the header digest, a fingerprint of its content, for each request. A changed header starts
a new series with a recorded reason. Compaction replaces earlier conversation content with a
shorter representation and also starts a new series. This is the rule in invariant 16.

## Consequences

Stable prefixes support cache reuse and make local changes traceable. They do not guarantee a
provider cache hit or explain every cache miss. **Cost:** changing tools or other fixed content
requires a new series; conversation history cannot be edited freely in place.

Implementation is partial: the current header digest covers model identity, system text and tool
schemas, but not all model settings or an explicit skill catalog digest. The work loop also prunes
and resets context; its history-replacement boundaries need reconciliation with the append-only
rule. These gaps do not change the accepted decision.

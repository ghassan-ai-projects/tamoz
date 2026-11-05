# ADR-064 — A received channel file is a temporary handoff, never stored

**Status:** Accepted 2026-11-04
**Date:** 2026-10-09
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md) (the channels that receive files), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (the gateway writes the handoff), [ADR-061](./adr-061-the-talk-channel-is-a-browser-surface-whose-voice-is-presentation.md) (speech uses the same handoff)

A file a user sends over a channel passes from the gateway to the worker through a private folder and is deleted once the turn has read it, because keeping people's files is a liability no feature here needs.

## Context

The gateway and worker are separate processes, so received bytes need somewhere to wait. A database row or a kept file would be the easy answer, and would quietly turn Tamoz into an archive of whatever people send it. The owner decided on 2026-10-09 that a file is never kept unless a future user request or policy says so.

## Decision

- **The bytes wait in one private folder.** `Tamoz::Core::AttachmentSpool` writes `<runtime>/attachments/<name>` with mode 600. The request carries the handoff name and a digest, never the bytes, and a read refuses bytes that no longer match the digest.
- **The first work step deletes the file.** Once the opened turn holds what was read from it, `WorkAttachment#discard` removes it.
- **A file no turn will read does not wait.** The gateway deletes it when its request is not enqueued, and a sweep removes anything older than 24 hours.
- **Only what was read stays,** like a typed message: extracted text, a transcript, or the model's reading of an image. The turn also keeps the file's name, type, size and digest, never its bytes.
- **A missing file is said, not invented.** If the bytes are gone, the turn tells the model the file is no longer stored.

## Consequences

There is no stored copy of a user's file to protect, leak, or retain. **Cost:** a file cannot be read again in a later turn, so the user must resend it; a request that never runs keeps its file for up to 24 hours.

## Invariants

- 56 — a user channel is identified, bound, and grants nothing.
- 57 — channel delivery is ordered, bounded, and ambiguity-safe.

## Threat model

**Asset:** the contents of files users send. **Adversary:** another local user; anyone who later obtains the runtime folder or database.

| Threat | Mitigation |
|---|---|
| Another local user reads a waiting file | Mode 600 in a private directory |
| A handoff name escapes the folder | Names must be 64 hex characters |
| Bytes swapped while waiting | The digest is checked on read |
| Old files accumulate | Deleted on read or refusal; swept after 24 hours |

**Residual risk:** what was read, and the file's name, type, size and digest, stay in the record by design. The channel provider and any model provider that receives the file keep it under their own terms, which Tamoz cannot enforce.

## History

- 2026-11-04: recorded at the owner's request; the owner decided the rule on 2026-10-09.

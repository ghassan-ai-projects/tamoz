# ADR-043 — Telegram v1 is deny-only and reference-bound (RETIRED)

**Status:** Retired 2026-10-01 — superseded by [ADR-049](../adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md)
**Date:** 2026-08-10

This decision is no longer in force as its own record. It made Telegram v1 deny-only — a chat
identity could deny a pending interrupt but never approve one, and the `chat_grants` and
`headless_auto_approvals` counters had to stay zero — and it bound each button to a single-use,
digest-stored reference that activates only after a durable send receipt. ADR-049 replaced the
deny-only rule with evidence-gated approval, and the 2026-09-24 policy lets the bound correspondent
approve. The reference-binding rule survives and is stated in ADR-049.

- **Why it was retired:** [`RETIRED.md`](../RETIRED.md).

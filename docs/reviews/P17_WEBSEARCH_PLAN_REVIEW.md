# P17 websearch plan review

Verdict: accept-with-required-corrections (revision 2 integrated corrections 1–8).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P17_WEBSEARCH_PLAN.md` revision 1 against `MCP_DESIGN.md`,
INVARIANTS.md 23/24/35–37, the P10 plan (ServerConfig/supervisor/Invocation), DR-2,
the P8 profile surface, and the scorecard's `network_enforcement` reporting.

## Findings and dispositions

| # | Sev | Section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| 1 | Critical | §2/DoD | Real adapter is documentation, not a capability; the outcome sentence is false as written | Adapter IMPLEMENTED behind an operator gate (default-disabled, provider config + grant); resolution/range-check/redirect logic as tested units behind an injectable resolver seam; live network = recorded deferral; outcome sentence amended to "capability surface" |
| 2 | Critical | §2/§5 | "Runtime egress mismatch audited at invocation" unimplementable: the supervisor sees stdio/stderr only, never the child's sockets | Enforcement point named: operator-side server egress config IS the enforcement; Tamoz pins + validates the declaration; self-reported comparison is author_claimed, no enforcement value; residual trust boundary stated (Tamoz never makes an outbound call) |
| 3 | High | §3/W3 | SSRF/private-range proof doesn't test real code; fixture has no resolver; single pre-connect check loses to DNS rebinding | Per-hop resolve→range→allowlist on every connection + redirect target; IP pinning/second resolution; redirect hop bound; no credential/header forwarding across hosts; W3 runs against adapter units with a rebinding stub resolver |
| 4 | Critical | §1/§7 | `network_enforcement` claim has no mechanism; in-process isolation cannot support it | Named mechanism (sandbox-exec'd subprocess with network self-test probe + hard-abort, agent subtree denied) or keep `not_claimed`; demonstrable claim = "entire agent subtree denied; search demonstrated against a fixture" |
| 5 | High | §3/DoD | P8 resume loses the egress pin: `authority_snapshot`/`AUTHORITY_KEYS` must carry the egress section | Egress joins the authority snapshot; resume mismatch stops typed (verify-egress-binding, mirroring verify_skill_binding!) |
| 6 | High | §5/W6 | Credential-shaped search query ARGUMENTS undefined; sweep omits the effect journal's invocation args | Invocation-time reject (fail closed); W6 sweep extends to effect-journal invocation args; operator-side server logs = operator-gate responsibility |
| 7 | Medium | §3/W7 | DR-2 egress scope under-implemented (connect-failures only; missing budget breach; no self-reset refusal) | Both DR-2 open conditions (connect + budget breach); W7 adds the unauthorized/self-reset refusal assertion |
| 8 | Medium | §3 | Profile-side duplication + budget drift | Reuse the existing tamoz-agent validator (duplication only across the gem boundary); map egress budgets onto `ServerConfig::Budgets` or define precedence |

Over-scope finding: the pinned-endpoint-tool fallback is P10-D2 work (its SSRF/redirect
policy) — DROPPED from P17 with the P10-D2 entry condition recorded; the adapter's
policy module is named as the SSRF/redirect policy artifact owner with the P10-D2
handoff.

## Held-out probes

Injection-following scripted model (P9-literal oracle: tool surface + plan digest +
no fabricated approval); credential-shaped query arg in journal; redirect to
169.254.169.254 via exotic literals + rebinding; server runtime egress deviating from
the declaration (not detectable — enforcement is operator-side, stated); agent opening
a socket directly (network_enforcement mechanism or honest not_claimed).

## Status

Corrections integrated in `docs/P17_WEBSEARCH_PLAN.md` revision 2.

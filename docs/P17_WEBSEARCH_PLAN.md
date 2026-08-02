# P17 — Websearch capability and egress policy: implementation plan

Status: accepted for implementation (revision 3 — checkpoint deep-review dial-path and
proof-baseline corrections integrated; see
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Source question: "can we have a websearch tool and give it to the agent?" — answered
yes, as a governed capability, never a raw fetch; this is the phase.
Authoritative inputs: `MCP_DESIGN.md`, invariants 23, 24, 35–37, the P10 plan (the
capability plane + P10-D2's deferred SSRF/redirect policy), `P8_TRUSTED_PROFILES_PLAN.md`
(the profile surface this phase extends), DR-2 (egress circuit scope), and SECURITY.md.
Depends on: P10 close, P16, DR-2. Activates after P16.

## 1. Scope commitment (corrected outcome sentence)

Give the agent ONE governed read-only websearch capability — a provider adapter whose
egress is policy-controlled, whose results are untrusted bounded evidence, whose health
is circuit-protected — with NO raw URL fetch, NO free-form browsing, and NO
exfiltration path.

**Outcome sentence (amended from revision 1's overclaim):** the phase ships the
governed websearch capability **surface** — admission + egress policy + invocation +
bounding/attribution + circuit + a REAL provider adapter implemented behind an
operator gate — and demonstrates it against an in-tree fixture in the gate. The
live-network validation run is a recorded deferral (operator-gated, never in CI). The
capability is the adapter + governance; the fixture is the test vehicle.

| Outcome | Proof |
|---|---|
| governed websearch capability surface admitted through the P10 surface | `ServerConfig` egress member (P10 contract change, recorded) OR the egress policy lives in the P8 profile with P10 admission pinning the declaration shape — one of these, stated, with W1 validation |
| real provider adapter IMPLEMENTED behind an operator gate | adapter code ships, default-disabled, enabled by explicit provider config + grant; its resolution/range-check/redirect logic are tested units behind an injectable resolver seam (never the live network in CI) |
| egress policy exists and is enforced | `egress:` section in the P8 profile; enforcement point NAMED (below); the authority snapshot carries it (correction 5) |
| results are untrusted bounded evidence | output bounded/stripped/attributed (`author_claimed`); never policy; never auto-injected; `:reported` evidence only |
| egress health is circuit-protected | DR-2 egress scope with BOTH open conditions (connect failures + budget breach) or the deferral recorded (correction 7) |
| adversarial matrix passes | per-hop SSRF/redirect/credential-param/oversize/injection vectors typed-rejected or bounded (correction 3) |
| scorecard honesty | `network_enforcement` claim made only with a named mechanism, or stays `not_claimed` (correction 4) |

Non-goals (binding): no `web_fetch`/`browse` raw-URL tool; no `file://`/internal
schemes; no auto-redirect outside per-hop allowlist checks; no credentials in query
strings, state, content, or logs; no HTML-into-prompt; no results as policy; no
auto-injection into system context. The pinned-endpoint-tool fallback is DROPPED from
this phase (it is P10-D2's SSRF/redirect policy territory; the P10-D2 entry condition
"stdio proofs green" gates it — recorded, not re-scoped here).

## 2. Capability shape — decision

Primary: an **MCP server capability** (`websearch` server admitted via `ServerConfig`)
with the server owning the HTTP stack (P10-D2 stays deferred for Tamoz itself).

**Enforcement point (correction 2 — the honest claim):** the supervisor sees the child
only via stdio/stderr; it CANNOT observe the child's sockets. Therefore: the
**operator-side server deployment enforces its own egress** (its HTTP stack's allowlist
+ range checks); **Tamoz pins the declaration and validates its shape**; any "runtime"
comparison is a SELF-REPORTED, `author_claimed` check with no enforcement value
(invariant 35: a self-report is not policy). The residual trust boundary is stated
plainly: **Tamoz itself never makes an outbound call; the network-capable process is
operator-supplied and its egress is enforced outside Tamoz.** The plan claims that —
not "audited at invocation".

**The real adapter (correction 1):** ships IMPLEMENTED behind an operator gate —
default-disabled, enabled by explicit provider config + operator grant. Its
resolution/range-check/redirect logic are units tested via an injectable resolver stub;
the gate never touches the live network. Live-network validation is the recorded
deferral. The fixture server (in-tree, SDK-built, deterministic) demonstrates the
governance path in CI; it cannot exhibit resolution failures, so W3 runs against the
adapter's units with a stub resolver serving a rebinding sequence.

## 3. Egress policy surface (P8 profile extension)

```yaml
egress:
  allowlisted_hosts: ["api.search.example"]   # exact FQDNs; no wildcards, no IP literals in v1
  schemes: ["https"]
  deny_private_ranges: true                   # enforced per-hop at the server boundary
  max_request_bytes: 2048
  max_response_bytes: 65536
  connect_timeout_s: 10
  redirect_max_hops: 3
  circuit: { threshold: 3, scope_type: egress, budget_breach: true }   # DR-2 both conditions (correction 7)
  credential_refs: ["SEARCH_API_TOKEN"]       # names only
```

Validation (fail-closed): hosts absolute DNS, no wildcards/IP literals/ports≠443;
https-only; `deny_private_ranges` per-hop (below); credential-shaped names rejected from
non-ref lists — **reusing the existing `tamoz-agent` validator inside the profile**
(`SECRET_KEY_DENYLIST`/`CREDENTIAL_REF_PATTERN`/`validate_strings!`); duplication only
across the gem boundary (the `tamoz-mcp`-side copy, per the P8-E precedent). Budgets:
map onto `ServerConfig::Budgets` or define precedence — one budget vocabulary, no drift
(correction 8).

**Authority snapshot (correction 5):** the `egress:` section joins
`authority_snapshot`/`AUTHORITY_KEYS` (profile.rb), so a resumed checkpoint re-pins the
egress declaration; a resume whose stored egress pin mismatches the loaded profile stops
typed (verify-egress-binding, mirroring `verify_skill_binding!`). Without this, an
operator adding egress to a profile and resuming an old session would run it without
the pin — silent widening, invariant 35/36.

## 4. SSRF / private ranges — per-hop contract (correction 3)

- Resolve + range-check + allowlist-check run **on every connection AND every redirect
  target** (never once before connecting — a TTL-0 rebinding DNS defeats a single
  pre-connect check).
- The validated address is the address actually passed to the socket dialer; TLS still
  verifies the allowlisted hostname through SNI/certificate validation. A second DNS
  lookup comparison by itself is NOT an enforcement mechanism because it leaves a
  check-to-connect resolution race. Every redirect repeats resolve → classify → pin →
  dial. Redirect hop bound is 3; no credential/header forwarding across hosts.
- IPv6 literals, IPv4-mapped (`::ffff:127.0.0.1`), and decimal/hex/octal IP forms are
  neutralized by the config rule (no IP literals in the allowlist) AND by the per-hop
  check (redirect targets re-run the full check, not just "off-list fails").
- W3 runs against the adapter's resolution unit with an injectable resolver stub
  serving a rebinding answer sequence (the fixture server has no resolver and cannot
  exhibit the failure).

## 5. Trust model and invocation

Results: bounded, control-stripped, attributed ("remote content from server
`websearch`"), marked `author_claimed` (invariant 35: content never grants). Invocation
taxonomy = P10 §6 table (provider error → `ToolArgumentError` `mcp_remote_error:`;
timeout before send → `mcp_unavailable:`; `:read_only` retry allowed; wire corruption →
`ToolPolicyError`; circuit open → typed unavailable).

**Injection proof (P9-analog, made literal — correction on W5):** a scripted model
ATTEMPTS to follow a search-result injection (names a capability/tool, claims
pre-granted approval). The oracle asserts, exactly like the P9 `skill-no-authority`
case: the injected tool name never appears in the toolbox surface; every executed step
is bound by the approved-plan digest; no approval was fabricated; no `tool_started`
outside the allowed list. Search results are adversarial BY CONSTRUCTION (unlike
operator-vetted skill content) — the scripted model tries to follow them.

**Credential-shaped search query arguments (correction 6):** invocation-time behavior
defined — a credential-shaped argument VALUE is rejected at invocation (typed
`ToolArgumentError`, no call) or scrubbed-and-marked (chosen: reject — fail closed);
the W6 sweep extends to the effect journal's invocation arguments, not just the session
record + stderr ring. Operator-side server logs are outside Tamoz's reach — stated as
an operator-gate responsibility.

Retrieval semantics: results are `:reported` evidence at best for P11 memory;
never `:observed`; the descriptor's description states this to the model.

## 6. Tests and adversarial matrix (revised)

- W1 admission: bad host/scheme/port/credential-shaped env rejected; egress shape
  validated; authority-snapshot carries the egress pin (resume mismatch stops typed).
- W2 invocation: search success bounded/attributed; oversize → bounded + circuit
  counter; provider error → typed; timeout → typed; corrupt frame → PolicyError.
- W3 per-hop SSRF: adapter units with injectable resolver — localhost/private-range
  targets refused at connect AND at each redirect hop; rebinding sequence refused and
  the dial-spy receives exactly the validated IP; exotic literals neutralized; off-allowlist redirect
  fails typed.
- W4 redirect: hop bound enforced; no credential/header forwarding across hosts.
- W5 injection: scripted model follows the payload → tool surface unchanged, plan
  digest binds every step, no fabricated approval (P9-literal assertions).
- W6 credentials: no credential value in query args (rejected at invocation), state,
  content, or logs; sweep covers the effect journal's invocation args.
- W7 circuit: 3 connect failures → egress circuit `open`; no outbound while open;
  budget breach opens too; unauthorized/self-reset REFUSED (DR-2 D4 assertion);
  reset via the authority path.
- W8 scorecard case `agent.websearch-governed` (mandatory): the agent plans
  `websearch:search` through review + approval, executes through the effect journal;
  the oracle proves pinned descriptor digest, bounded/attributed results, no fetch
  path, no credential leak, circuit opened on induced failure, teardown left no
  process. It adds exactly one case to the baseline measured at P17 start; safety 0.

## 7. Scorecard network_enforcement (correction 4)

The claim is made ONLY with a named mechanism, or stays `not_claimed`. Named option:
the scorecard runs as a subprocess under the m1/m2 `sandbox-exec` profile (deny-all
network + self-test probe that requires an actual `Socket.tcp` to fail + hard-abort
when the platform cannot enforce), with the agent's entire subtree network-denied;
`isolation`/`network_enforcement`/gate values updated to match (real harness work,
budgeted). The DEMONSTRABLE claim is "the entire agent subtree is network-denied; the
search capability was demonstrated against a fixture" — NOT "agent denied while the
governed server egresses" (the sandbox cannot show a two-zone picture). If the harness
work is out of scope, `not_claimed` stays and the stop criterion is adjusted
accordingly — no claim without the mechanism.

## 8. Failure model

| Situation | Type | Behavior |
|---|---|---|
| egress policy violation (host/scheme/range) | `EgressPolicyError` (terminal) | refused at admission/invocation; no outbound |
| circuit open | `CircuitOpen` (DR-2, egress scope) | typed unavailable; observation only |
| credential-shaped query arg | `ToolArgumentError` (reject) | no call issued; typed |
| provider-declared search error | `ToolArgumentError` (`mcp_remote_error:`) | repairable evidence |
| redirect off-allowlist / over hop bound | `ToolPolicyError` | terminal; no follow |
| credential-shaped result field | rejected/bounded at output | never rendered as fillable |
| self-reported egress mismatch | advisory (`author_claimed`) | surfaced, never enforcement |

## 9. Stop / redesign criteria

- Any path by which model text can cause an outbound call outside the per-hop checks
  (exfiltration/SSRF), or any result content altering policy/approval/tool surface.
- `network_enforcement` claimed without the named mechanism.
- The phase ships without the real adapter units (resolver seam), the W3 per-hop suite,
  or the scorecard case.

## 10. Definition of done

- [ ] Egress policy section + authority-snapshot pinning + W1 validation; one budget
      vocabulary (ServerConfig::Budgets mapping or precedence).
- [ ] Real provider adapter implemented behind the operator gate with injectable
      resolver units; live network = recorded deferral.
- [ ] P10 invocation + DR-2 egress circuit (both conditions) wired; W2–W7 green.
- [ ] Scorecard case `agent.websearch-governed` green; all P17-start cases unchanged,
      exactly one case added; safety 0.
- [ ] `network_enforcement` resolved (named mechanism + harness work, or honestly
      `not_claimed`).
- [ ] `rake ci` both locales; trackers updated; deferrals (live network, P10-D2
      handoff for the SSRF/redirect policy artifact) recorded.

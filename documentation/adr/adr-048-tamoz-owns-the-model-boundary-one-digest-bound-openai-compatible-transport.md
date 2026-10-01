# ADR-048 — Tamoz owns the model boundary: one digest-bound OpenAI-compatible transport

**Status:** Accepted 2026-08-26
**Date:** 2026-08-26
**Tier:** F
**Implementation:** Complete
**Supersedes:** [ADR-003](./adr-003-reuse-rubyllm-public-values.md), [ADR-051](./adr-051-rubyllm-removed.md)
**Relates to:** [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (every model call is a journaled effect)

Every model call — session, one-shot, and stream episode — goes through one Tamoz-owned client that
speaks the OpenAI-compatible chat protocol, resolves its credential in one place, and binds the exact
request and provider configuration into the durable receipt. Messages, tools, and content blocks are
Tamoz value types; no third-party LLM SDK is in the runtime.

## Context

Tamoz began "over `ruby_llm`", passing its message and tool types through public APIs (ADR-003). A
durable receipt needs the exact request bytes and the exact provider configuration, and a replay must
reproduce the request identity. A second SDK's message model hid the wire bytes, kept a second
credential and failure path, and had to be kept in sync with Tamoz's own types. Supporting each
provider's native protocol would multiply that by the number of providers.

## Decision

- `Tamoz::Agent::ModelClientFactory` (in `tamoz-agent-kernel`) is the only runtime credential
  resolver. It reads the credential named by the trusted profile, with no generic fallback, and
  builds the `EpisodeModelTransport`.
- Every model call uses one canonical request/response projection over the OpenAI-compatible
  protocol. Providers that need a native protocol (Anthropic, Gemini) are reached through
  `openrouter` with a provider-qualified model id; native protocols fail closed.
- The provider configuration digest binds provider, model, endpoint, protocol, settings, profile
  digest, and safety posture — never credential values. The model receipt's identity is the request
  digest plus that configuration digest.
- Message, tool, and content-block fidelity are Tamoz-native types; `Tamoz::StateCodec` is the
  lossless durable codec. No gemspec depends on `ruby_llm`, and requiring `tamoz/graph` loads no
  model client or HTTP library.

## Consequences

One credential path, one failure taxonomy, exact receipts, and replay by request identity. **Cost:**
Tamoz owns message/tool/content modeling it once borrowed, and native-protocol features (for example,
provider-specific caching controls) are reachable only as far as the OpenAI-compatible surface or
OpenRouter exposes them.

## Invariants

- 11 — the graph engine loads no model client.
- 21 — replay-safe effects (model calls are effects).

## Threat model

**Asset:** model credentials and the integrity of model receipts. **Adversary:** a misconfigured or
hostile profile, endpoint, or provider response.

| Threat | Mitigation |
|---|---|
| Credential leaks into a digest, receipt, or error | Digest binds configuration, never credential values; failures are redacted |
| A profile points a role at an unexpected provider | Factory rejects a model or provider that does not match the profile role |
| A generic env var supplies the wrong key | No generic fallback; only the profile-named credential |
| A received failure is retried and double-billed | The transport does not retry a received failure |
| A malformed response becomes a fake success | Typed failed model call |

**Residual risk:** the endpoint itself sees every prompt; choosing a provider is a trust decision the
operator makes in the profile.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep `ruby_llm` behind a Tamoz-owned projection *(retrospective, 2026-10-01)* | Credible; lost because the receipt needs exact wire bytes the SDK does not expose, and two message models must be kept in sync |
| One adapter per native protocol *(retrospective, 2026-10-01)* | Multiplies credential, failure, and projection paths per provider |
| A compatibility alias for the retired `RubyLLMModel` | Nothing shipped depended on it (ADR-059) |

## Reopen when

A needed provider capability is unreachable through the OpenAI-compatible surface and OpenRouter.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Profile-named credential only; no generic fallback | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb` | `test/model_client_factory_test.rb` — `test_factory_requires_the_profile_credential_without_generic_fallback` | — |
| Native protocols and unknown providers fail closed | same | `test/model_client_factory_test.rb` — `test_native_protocols_and_unknown_providers_fail_closed` | — |
| Configuration binds without the secret | same | `test/model_client_factory_test.rb` — `test_factory_binds_profile_and_explicit_endpoint_configuration_without_secret` | — |
| Receipt identity changes with request and provider configuration | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` | `test/agent_model_receipt_test.rb` — `test_logical_key_changes_with_provider_configuration` | — |
| No retry of a received failure | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` | `test/model_transport_parity_test.rb` — `test_transport_does_not_retry_a_received_failure` | — |
| The graph loads no model, eval, or HTTP package | `tamoz-graph` | `test/dependency_isolation_test.rb` — `test_graph_loads_no_model_eval_or_adapter_package` | — |

## History

- 2026-08-26 — Accepted as the transport decision; `RubyLLMModel` retired.
- 2026-10-01 — Absorbed ADR-051 (no `ruby_llm` anywhere; native message/tool types).

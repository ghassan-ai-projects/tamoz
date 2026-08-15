# frozen_string_literal: true

module Tamoz
  module Agent
    class Error < Tamoz::Error; end

    # Raised when a model document cannot be parsed. Its message may quote provider
    # text (`Plan.parse` interpolates `JSON::ParserError#message`, `RubyLLMModel`
    # interpolates the provider exception), so it deliberately does NOT include
    # `Tamoz::DisclosableMessage`.
    class ProtocolError < Error; end

    # P0B/§5: a diagnosis catalog (trusted SituationSpec config, not model
    # output) is structurally invalid — empty, missing `unknown`, duplicate or
    # malformed code, or oversized. Terminal: the worker refuses before a model
    # call, exactly like a skill-digest mismatch. Distinct from `ProtocolError`,
    # which is untrusted-model-document territory.
    class DiagnosisCatalogError < Error; end

    # P0B/§4.3/§8.1: a model-call identity or receipt was constructed with an
    # invalid shape — a bad status, a malformed digest, or usage that fabricates
    # zero instead of declaring itself unavailable. A construction-time guard, so
    # a malformed receipt can never enter the durable journal.
    class ModelReceiptError < Error; end

    # Raised when every plan attempt failed review. D-8 Fix C (RC-3): the raise site
    # authors the message — either a bounded summary of the last attempt's
    # STRUCTURAL-layer issues (Tamoz-generated validation text) or a generic phrase —
    # so the class opts in to `Tamoz::DisclosableMessage` like `ToolError`. It must
    # never carry model-authored semantic feedback or provider payloads, which is why
    # the structural-only rule lives at the raise site.
    class PlanRejectedError < Error
      include Tamoz::DisclosableMessage
    end
    class ApprovalDeniedError < Error; end

    # P9: a resumed session cannot bind the exact skill trees it was planned
    # against. This is a stop, not a recoverable tool result: continuing would run
    # an accepted plan under instructions that have since changed (invariant 41).
    class SkillSnapshotUnavailableError < Error; end

    # P10 §5: a resumed session cannot bind the exact MCP catalog snapshots it was
    # planned against. This is a stop, not a recoverable tool result: continuing
    # would run an accepted plan against server-declared schemas that have since
    # changed (epoch rules — no silent schema substitution). `tamoz-mcp` raises its
    # own `Tamoz::Mcp::CatalogSnapshotUnavailableError` for the invocation-level
    # digest gate; this is the agent-surface twin, raised by
    # `Session#verify_mcp_binding!` when the pinned `mcp_catalogs` no longer match
    # the caller's current source.
    class McpCatalogSnapshotUnavailableError < Error; end

    # P17 (correction 5): a resumed session cannot bind the egress declaration it
    # was pinned to. A changed egress declaration is a changed network policy
    # (invariant 35/36) — resuming an accepted plan under different egress is the
    # silent widening the correction names. Raised by
    # `Session#verify_egress_binding!` when the pinned `egress_pin` in the session
    # record no longer matches the egress section of the profile the session was
    # constructed with.
    class EgressBindingUnavailableError < Error; end

    # DR-5 D1: profile role resolution failed for a referenced role at session
    # start — most commonly a credential reference whose env-var name is not set.
    # Terminal: the session refuses to start, before any model I/O, checkpoint, or
    # request enqueue. The untyped `ArgumentError` raised by the model factory is
    # wrapped here at the boundary so the message names the role and the reference.
    class ProfileRoleUnavailableError < Error; end

    # DR-5 D1: an override value entering the durable `profile_roles` record is
    # credential-shaped. Terminal: nothing secret-shaped may be recorded (invariant
    # 24), and the refusal happens at construction, before any session record or
    # checkpoint exists. The existing profile secret predicates
    # (`SECRET_VALUE_PATTERNS` / `ENTROPY_PATTERN`) are the gate.
    class ProfilePolicyError < Error; end

    # P1/§3.1: the episode frame failed a deterministic gate — a prompt digest
    # mismatch, malformed facts, or an unverifiable catalog. Terminal: the
    # episode fails typed before any model call. Distinct from ProtocolError,
    # which is untrusted-model-document territory.
    class EpisodeFrameError < Error; end
  end
end

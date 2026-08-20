# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  # DR-2 — the ONE circuit engine (`docs/DR2_DURABLE_CIRCUIT_PLAN.md`).
  #
  # There is exactly one circuit RECORD type and one set of transition rules in
  # this repository; four scopes (`server`, `rule_target`, `schedule`, `egress`)
  # instantiate it. Persistence is a thin adapter over the same engine:
  #
  #   * `Tamoz::SQLite::CircuitStore`   — the durable record in the Store
  #     (namespace `tamoz.circuit.<scope_type>`, key `<scope_digest>`).
  #
  # `tamoz-core/pool.rb`'s liveness circuit is deliberately NOT an instantiation
  # of this record (DR-2 origin note): process-local thread liveness is not a
  # scope health condition and operator-evidence reset is meaningless there.
  #
  # The stored value is a string-keyed Hash (StateCodec does not support symbols
  # and sorts object keys, so serialization is canonical for free). Every
  # caller-supplied context enters the record ONLY as a domain-separated digest,
  # so no free-form or sensitive payload can reach a durable circuit record
  # (invariants 18 and 24).
  module Circuit
    # Invariant 18: every durable record carries its format version and refuses
    # a newer one before any partial load.
    FORMAT_VERSION = 1

    NAMESPACE_PREFIX = "tamoz.circuit."
    SCOPE_DIGEST_DOMAIN = "tamoz.circuit.scope.v1\n"
    EVIDENCE_DIGEST_DOMAIN = "tamoz.circuit.evidence.v1\n"
    CONTEXT_DIGEST_DOMAIN = "tamoz.circuit.context.v1\n"
    CONDITIONS_DIGEST_DOMAIN = "tamoz.circuit.conditions.v1\n"

    # Explicit bounds (DR-2 §2/§9.3). `MAX_CIRCUIT_OWNERS` is the plan's
    # mandated minimum of 64 (the P13 2–50 poller proof needs >= 50).
    MAX_CIRCUIT_OWNERS = 64
    # `conditions_met` is ring-buffered so the evidence list cannot grow past
    # the codec's 4 MiB cap (DR-2 C8).
    MAX_CONDITIONS_MET = 32
    # Per-condition window/rate accumulators are bounded the same way.
    MAX_WINDOW_EVENTS = 64
    # Fingerprints tracked for the "same fingerprint thrice in one run" rule.
    MAX_RUN_FINGERPRINTS = 32
    MAX_IDENTITY_BYTES = 256
    DEFAULT_PROBE_WINDOW_MS = 30_000

    STATES = %w[closed open].freeze
    DIGEST_PATTERN = Tamoz::Core::JCS::DIGEST_PATTERN
    # DR-2 D10: owner ids are stable deployment/policy identities. A per-process
    # UUID would let a restart orphan its own evidence, so UUID churn is refused
    # at the boundary rather than silently accepted.
    UUID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    IDENTITY_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._:/@+-]*\z}

    module_function

    # The Store namespace for a scope type. The KEY is the scope digest, never a
    # raw `rule_id/target` concatenation: that avoids delimiter collisions, leaks
    # through key enumeration, and `Store::MAX_NAME_BYTES` failures (DR-2 §2).
    def namespace_for(scope_type)
      "#{NAMESPACE_PREFIX}#{Registry.fetch(scope_type).scope_type}"
    end

    # Domain-separated digest of the canonical typed scope identity.
    def scope_digest(scope_type:, scope_id:)
      digest_of(
        {
          "scope_type" => Registry.fetch(scope_type).scope_type,
          "scope_id" => identity!(scope_id, name: "circuit scope id")
        },
        domain: SCOPE_DIGEST_DOMAIN
      )
    end

    # A domain-separated, canonical-JSON digest. Locale-independent: every
    # literal is ASCII and the payload is generated, never read from a file.
    def digest_of(value, domain:)
      Tamoz::Core.digest(domain, digestable(value))
    end

    # Caller context never enters a record verbatim — only this digest does.
    # A `Tamoz::Secret` (or any other unsupported value) is refused rather than
    # stringified, so a credential cannot reach a durable record through the
    # circuit path (invariant 24).
    def context_digest(value)
      return nil if value.nil?

      digest_of(value, domain: CONTEXT_DIGEST_DOMAIN)
    end

    def identity!(value, name:, error_class: Tamoz::ConfigurationError)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise error_class, "#{name} must be a String"
      end

      text = value.to_s.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.empty? &&
             text.bytesize <= MAX_IDENTITY_BYTES && IDENTITY_PATTERN.match?(text)
        raise error_class,
              "#{name} must be a bounded identifier of at most #{MAX_IDENTITY_BYTES} bytes"
      end

      text.freeze
    end

    # DR-2 C2/D10: stable deployment/policy identity, never a random process
    # UUID. Refused as a policy violation (invariant 17 — this is not a
    # repairable value the caller can iterate on).
    def owner_id!(value)
      text = identity!(value, name: "circuit owner id", error_class: CircuitPolicyError)
      if UUID_PATTERN.match?(text)
        raise CircuitPolicyError,
              "a circuit owner id must be a stable deployment identity; a " \
              "per-process UUID would orphan its own evidence across a restart"
      end

      text
    end

    # Recursively rejects anything that cannot cross the durable boundary before
    # it is ever digested or stored.
    def digestable(value)
      case value
      when Tamoz::Secret
        raise SensitiveValueError,
              "a Tamoz::Secret cannot enter a circuit record or its evidence digest"
      when Hash
        value.to_h { |key, entry| [String(key), digestable(entry)] }
      when Array
        value.map { |entry| digestable(entry) }
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      when Symbol
        value.to_s
      else
        raise UnsupportedValueError,
              "#{value.class} cannot enter a circuit record or its evidence digest"
      end
    end
  end
end

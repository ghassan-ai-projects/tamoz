# frozen_string_literal: true

require "digest"

module Tamoz
  module Mcp
    module Websearch
      # The egress-scope circuit behind the Supervisor's `CircuitStore` seam
      # (DR-2 §3, P17 correction 7). It satisfies the full duck-typed contract
      # the supervisor validates, so it drops into
      # `Supervisor.new(config, circuit_store: ...)` unchanged.
      #
      # BOTH DR-2 open conditions are implemented:
      #   (a) consecutive transport/connect failures >= `threshold` (the P10
      #       default of 3, taken from the egress declaration's circuit
      #       threshold), and
      #   (b) a budget breach — a response that exceeded the declared
      #       `max_response_bytes`. This is the NON-consecutive condition
      #       (DR-2 D1: never only the consecutive happy path): the profile's
      #       `circuit.budget_breach: true` is the operator's declared policy
      #       that a single oversize response opens the circuit.
      # A success resets the owner's consecutive counter only; it never closes
      # an open circuit (DR-2 §4: time alone never resets).
      #
      # Reset authority (DR-2 §5, egress row): `open → closed` requires the
      # operator command record — evidence carrying `authority: "owner"` and
      # an `operator_command_digest` (the sha256 of the operator's command
      # record). The gate lives on the record write, so no in-process caller
      # (the search capability itself) can reset its own circuit: an
      # evidence-free or non-operator reset is a typed `CircuitPolicyError`.
      class EgressCircuit
        CONDITIONS_DOMAIN = "tamoz.mcp.circuit.conditions.v1\n"
        OPERATOR_AUTHORITY = "owner"
        COMMAND_DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
        BUDGET_BREACH_KIND = :budget_breach

        attr_reader :scope_id, :threshold, :budget_breach, :reset_authority

        def initialize(threshold:, scope_id:, budget_breach: true, reset_authority: OPERATOR_AUTHORITY)
          unless threshold.is_a?(Integer) && threshold >= 1
            raise ValidationError, "egress circuit threshold must be an integer >= 1"
          end
          unless scope_id.is_a?(String) && !scope_id.empty?
            raise ValidationError, "egress circuit scope_id must be a non-empty string"
          end
          unless budget_breach == true || budget_breach == false
            raise ValidationError, "egress circuit budget_breach must be true or false"
          end

          @threshold = threshold
          @scope_id = scope_id
          @budget_breach = budget_breach
          @reset_authority = String(reset_authority).freeze
          @failures = 0
          @state = :closed
          @last_failure_kind = nil
          @last_failure_context = nil
          @reset_evidence = nil
          @mutex = Mutex.new
        end

        # Atomic read-modify-write: update the counter, then evaluate BOTH open
        # predicates inside the write so the open state is never lost between a
        # durable increment and a separate open decision (DR-2 C1). A budget
        # breach opens immediately (the declared non-consecutive condition);
        # every other failure kind counts consecutively toward the threshold.
        def record_failure(kind: :transport, context: nil)
          @mutex.synchronize do
            capture_failure(kind, context)
            transition_on_failure
          end
        end

        def record_success
          @mutex.synchronize do
            unless @state == :open
              @failures = 0
              @state = :closed
            end
            @state
          end
        end

        def open?
          @mutex.synchronize { @state == :open }
        end

        def failures
          @mutex.synchronize { @failures }
        end

        # The authority-gated reset (DR-2 §5). `evidence:` must name the
        # operator authority and carry the operator command digest; anything
        # else — no evidence, a non-operator authority, a component's
        # self-reset — is refused as a typed policy violation and the circuit
        # stays open.
        def reset(evidence: nil)
          @mutex.synchronize do
            validate_reset_evidence!(evidence)
            @failures = 0
            @state = :closed
            @reset_evidence = evidence.freeze
            @state
          end
        end

        def reset_evidence
          @mutex.synchronize { @reset_evidence }
        end

        def last_failure_kind
          @mutex.synchronize { @last_failure_kind }
        end

        def last_failure_context
          @mutex.synchronize { @last_failure_context }
        end

        # Typed digest of the failure state a reset clears — the "conditions
        # met" evidence (DR-2). Deterministic given the same failure state.
        def conditions_digest(server_id)
          sha256_digest(conditions_payload(server_id))
        end

        private

        def capture_failure(kind, context)
          @last_failure_kind = kind.to_sym
          @last_failure_context = context.nil? ? nil : context.to_h.freeze
        end

        def transition_on_failure
          if @budget_breach && @last_failure_kind == BUDGET_BREACH_KIND
            @state = :open
            return @state
          end

          @failures += 1
          @state = @failures >= @threshold ? :open : :degraded
        end

        def conditions_payload(server_id)
          CONDITIONS_DOMAIN + CanonicalJSON.dump(
            "scope_type" => "egress",
            "server_id" => server_id.to_s,
            "failure_kind" => last_failure_kind&.to_s,
            "context" => last_failure_context || {}
          )
        end

        def sha256_digest(payload)
          "sha256:#{Digest::SHA256.hexdigest(payload)}"
        end

        def validate_reset_evidence!(evidence)
          validate_evidence_is_hash!(evidence)
          validate_evidence_authority!(evidence)
          validate_evidence_digest!(evidence)

          evidence
        end

        def validate_evidence_is_hash!(evidence)
          return if evidence.is_a?(Hash)

          raise CircuitPolicyError,
                "the egress circuit reset was refused: evidence must be a mapping " \
                "naming the operator authority and command"
        end

        def validate_evidence_authority!(evidence)
          return if evidence["authority"] == @reset_authority

          raise CircuitPolicyError,
                "the egress circuit reset was refused: authority must be " \
                "#{@reset_authority.inspect} with the operator command record"
        end

        def validate_evidence_digest!(evidence)
          digest = evidence["operator_command_digest"]
          return if digest.is_a?(String) && COMMAND_DIGEST_PATTERN.match?(digest)

          raise CircuitPolicyError,
                "the egress circuit reset was refused: the operator command digest " \
                "is missing or malformed"
        end
      end
    end
  end
end

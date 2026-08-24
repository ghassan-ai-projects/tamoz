# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Healing
      # Invariant 33 / P12 §4 (C2) — the verification oracle IS a configured check.
      #
      # There is exactly ONE way to reach `recovered`: a recorded pass from the
      # deterministic, model-independent, digest-pinned configured check named in
      # the immutable rule. This module is the only place that can produce that
      # pass, and it reuses the EXISTING `run_check` machinery on
      # `Tamoz::Tools::Toolbox` (child process, credential-free environment,
      # bounded output, `CheckReceipt`) rather than inventing a second runner.
      #
      # What is deliberately NOT an input to `verify`: any model output, any
      # remediation narration, any exit-code-only signal, any "the tool returned
      # success" observation. `verify` takes the rule and the toolbox and nothing
      # else. A remediation that narrates "fixed and verified" therefore cannot
      # change the result by construction — `test_oracle_independence_*` asserts it.
      module Oracle
        DIGEST_DOMAIN = "tamoz.agent.healing.oracle.v1"

        # The verification result. `passed` is the ONLY gate on `recovered`.
        Result = Data.define(
          :passed, :oracle_digest, :observed_digest, :check_name, :outcome,
          :failure_signature, :reason
        ) do
          def to_h
            {
              "passed" => passed,
              "oracle_digest" => oracle_digest,
              "observed_digest" => observed_digest,
              "check_name" => check_name,
              "outcome" => outcome,
              "failure_signature" => failure_signature,
              "reason" => reason
            }
          end
        end

        module_function

        # The digest a rule pins. Covers the check NAME and its exact argv, so
        # repointing a check name at a different command invalidates the pin.
        # Computed from the toolbox's configured checks — operator authority — and
        # never from model or rule text.
        def digest_for(toolbox, check_name)
          argv = toolbox.checks[String(check_name)]
          if argv.nil?
            raise HealingContractError,
                  "no configured check named #{check_name.inspect}; the oracle must " \
                  "be a configured check (invariant 33)"
          end

          Tamoz::Core.digest("#{DIGEST_DOMAIN}\n", [String(check_name), argv])
        end

        # Runs the rule's pinned oracle. Returns a `Result`; NEVER raises for a
        # failing or absent check — an unavailable or mismatched oracle is a
        # verification FAILURE (design §8: "Unavailable or invalid verification
        # yields `escalated` or `circuit_open`, never `recovered`").
        def verify(rule:, toolbox:)
          oracle = rule.verification_oracle
          check_name = oracle.fetch("check_name")
          pinned = oracle.fetch("digest")
          observed = observe_digest(toolbox, check_name)

          return absent_result(pinned, check_name) if observed.nil?
          return mismatch_result(pinned, observed, check_name) unless observed == pinned

          receipt = toolbox.execute("run_check", {"name" => String(check_name)})
          assert_receipt!(receipt)
          result_from_receipt(receipt, pinned, observed, check_name)
        rescue Tamoz::Core::ToolError => error
          unavailable_result(rule.verification_oracle, error)
        end

        def observe_digest(toolbox, check_name)
          digest_for(toolbox, check_name)
        rescue HealingContractError
          nil
        end
        private_class_method :observe_digest

        def assert_receipt!(receipt)
          return if receipt.is_a?(Tamoz::Tools::CheckReceipt)

          raise HealingContractError,
                "the configured check did not return a CheckReceipt"
        end
        private_class_method :assert_receipt!

        def absent_result(pinned, check_name)
          Result.new(
            passed: false, oracle_digest: pinned, observed_digest: nil,
            check_name:, outcome: nil, failure_signature: nil,
            reason: "oracle_absent"
          )
        end
        private_class_method :absent_result

        def mismatch_result(pinned, observed, check_name)
          Result.new(
            passed: false, oracle_digest: pinned, observed_digest: observed,
            check_name:, outcome: nil, failure_signature: nil,
            reason: "oracle_digest_mismatch"
          )
        end
        private_class_method :mismatch_result

        def result_from_receipt(receipt, pinned, observed, check_name)
          Result.new(
            passed: receipt.passed?, oracle_digest: pinned, observed_digest: observed,
            check_name:, outcome: receipt.outcome,
            failure_signature: receipt.failure_signature,
            reason: receipt.passed? ? "oracle_pass" : "oracle_fail"
          )
        end
        private_class_method :result_from_receipt

        def unavailable_result(oracle, error)
          Result.new(
            passed: false, oracle_digest: oracle.fetch("digest"),
            observed_digest: nil, check_name: oracle.fetch("check_name"),
            outcome: nil, failure_signature: nil,
            reason: "oracle_unavailable:#{Tamoz::Core.serialized_tool_error_name(error.class.name)}"
          )
        end
        private_class_method :unavailable_result
      end
    end
  end
end

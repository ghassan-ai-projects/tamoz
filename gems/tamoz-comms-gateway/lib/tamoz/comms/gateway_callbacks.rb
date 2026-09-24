# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Resolves callback presses after the inbound disposition is durable.
      module Callbacks
        TOASTS = {
          approve: 'Approved', deny: 'Denied', stale: 'This is no longer waiting for an answer.',
          binding_mismatch: 'This button is not for you.',
          insufficient_evidence: 'Only the operator can approve this; Deny still works.'
        }.freeze
        SETTLED = %i[approve deny stale].freeze

        private

        # The toast and the cleared buttons are best-effort after durable admission: a
        # settled prompt shows no buttons, so nobody taps a question that was answered.
        def acknowledge_callback(envelope, outcome)
          return unless envelope['callback_query_id']

          @transport.signal(:ack, callback_query_id: envelope.fetch('callback_query_id'), text: TOASTS.fetch(outcome))
          return unless SETTLED.include?(outcome)

          @transport.signal(:clear_buttons, conversation_id: envelope.fetch('conversation_id'),
                                            message_id: envelope.fetch('callback_message_id'))
        rescue Comms::Error, NotImplementedError
          nil
        end

        # ADR-049: approval evidence is pinned by the prompt; deny is
        # unconditional and prompt consumption is a single-use CAS.
        def resolve_callback(envelope, now:)
          action, reference = split_callback(envelope.fetch('text').to_s)
          digest, prompt = callback_prompt(reference)
          return refuse_callback(envelope, 'ignored', 'unknown_reference', :stale, now:) unless active_prompt?(prompt)
          unless prompt_binding_matches?(prompt, envelope)
            return refuse_callback(envelope, 'rejected', 'binding_mismatch', :binding_mismatch, now:)
          end
          if action == 'approve' && approval_insufficient_evidence?(prompt)
            return refuse_callback(envelope, 'rejected', 'insufficient_evidence', :insufficient_evidence, now:)
          end

          outcome = record_callback_decision(envelope, prompt, digest, action, now:)
          outcome == :consumed ? action.to_sym : :stale
        end

        def refuse_callback(envelope, disposition, reason, outcome, now:)
          record_disposition(envelope, disposition:, reason:, now:)
          outcome
        end

        def callback_prompt(reference)
          digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
          [digest, @store.prompt(reference_digest: digest)]
        end

        def active_prompt?(prompt)
          prompt && prompt.fetch('status') == 'active'
        end

        def record_callback_decision(envelope, prompt, digest, action, now:)
          decision = Comms::DecisionRecord.build(
            thread_id: prompt.fetch('thread_id'), occurrence_id: prompt.fetch('occurrence_id'),
            interrupts: [], interrupt_digest: prompt.fetch('interrupt_digest'),
            direction: action, actor_kind: decision_actor_kind,
            actor_id: envelope.fetch('correspondent_id'), source: decision_source,
            decided_at: now, ttl_s: @descriptor.approvals.fetch(:prompt_ttl_s)
          )
          outcome = @store.consume_prompt(reference_digest: digest, decision_wire: decision.wire, now:)
          record_disposition(envelope, disposition: 'decision', reason: outcome.to_s, now:)
          outcome
        end

        def prompt_binding_matches?(prompt, envelope)
          prompt.fetch('surface_id') == envelope.fetch('surface_id') &&
            prompt.fetch('surface_revision') == envelope.fetch('surface_revision') &&
            prompt.fetch('correspondent_id') == envelope.fetch('correspondent_id') &&
            prompt.fetch('conversation_id') == envelope.fetch('conversation_id') &&
            prompt.fetch('prompt_receipt').to_s == envelope.fetch('callback_message_id').to_s
        end

        def approval_insufficient_evidence?(prompt)
          Comms::AuthorityEvidence.chat_bound <
            Comms::AuthorityEvidence.from(prompt.fetch('required_evidence'))
        end

        # `approve:<reference>` / `deny:<reference>`; a bare reference means deny.
        def split_callback(text)
          if text.start_with?('approve:', 'deny:')
            action, reference = text.split(':', 2)
            [action, reference.to_s]
          else
            ['deny', text]
          end
        end
      end
    end
  end
end

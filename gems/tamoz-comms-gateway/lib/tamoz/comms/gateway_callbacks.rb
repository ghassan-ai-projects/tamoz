# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Resolves callback presses after the inbound disposition is durable.
      module Callbacks
        private

        # answerCallbackQuery is best-effort after durable admission.
        def acknowledge_callback(envelope)
          return unless envelope['callback_query_id']

          @transport.signal(:ack, callback_query_id: envelope.fetch('callback_query_id'))
        rescue Comms::Error, NotImplementedError
          nil
        end

        # ADR-049: approval evidence is pinned by the prompt; deny is
        # unconditional and prompt consumption is a single-use CAS.
        def resolve_callback(envelope, now:)
          action, reference = split_callback(envelope.fetch('text').to_s)
          digest, prompt = callback_prompt(reference)

          unless active_prompt?(prompt)
            record_disposition(envelope, disposition: 'ignored', reason: 'unknown_reference', now:)
            return
          end

          unless prompt_binding_matches?(prompt, envelope)
            record_disposition(envelope, disposition: 'rejected', reason: 'binding_mismatch', now:)
            return
          end

          if action == 'approve' && approval_insufficient_evidence?(prompt)
            record_disposition(envelope, disposition: 'rejected', reason: 'insufficient_evidence', now:)
            return
          end

          record_callback_decision(
            envelope, prompt, digest, action, now:
          )
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

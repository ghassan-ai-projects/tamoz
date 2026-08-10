# frozen_string_literal: true

require 'digest'

require_relative 'commands'

module Tamoz
  module Comms
    # Pure private-chat admission for one normalized inbound update (design
    # §5). The decision is a function of the envelope, the deployed surface,
    # the durable binding and route — no I/O — so every disposition is
    # deterministic and testable. The gateway records the disposition
    # durably and, for :request, enqueues the turn (slice G).
    #
    # V1 rules: private chats only; a known command is a control disposition;
    # an unknown slash command is a typed unknown_command control reply and
    # never becomes model input; allowlist mode requires an active binding;
    # pairing mode requires a consumed pairing challenge; callbacks are
    # decisions (v1 deny-only, design §9), never requests.
    # The admission decision is one deterministic function of its inputs
    # (envelope, surface, binding, route); the metric smells measure the
    # decision table itself, not a choice to overload.
    # :reek:LongParameterList, :reek:ControlParameter, :reek:DuplicateMethodCall, :reek:DataClump
    # :reek:TooManyStatements, :reek:NilCheck
    # rubocop:disable Metrics/PerceivedComplexity -- the decision table IS
    #   the admission policy; splitting it would scatter the rules.
    module Admission
      # The disposition of one update. `thread_id` is the deterministic
      # conversation thread for :request; `control_reply` is the exact reply
      # text for :control/:rejected dispositions that answer the sender.
      Decision = Data.define(:disposition, :reason, :control_reply, :thread_id)

      module_function

      def decide(envelope, surface:, binding: nil, conversation: nil, bot_username: nil)
        return reject(:surface_disabled, 'the surface is disabled') if surface.disabled?
        return ignore(:unsupported_kind) unless %w[text command callback].include?(envelope.fetch('kind'))
        return reject(:group_chat, 'group chats are refused in v1') if group_chat?(envelope.fetch('conversation_id'))
        return reject(:unbound, 'the correspondent is not bound') if binding && binding.fetch('status') != 'active'
        return decision_disposition if envelope.fetch('kind') == 'callback'

        if envelope.fetch('kind') == 'command'
          command_disposition(envelope, bot_username:)
        else
          text_disposition(envelope, surface:, binding:, conversation:)
        end
      end

      # The deterministic per-conversation thread id (design §5):
      # `tg.<surface_id>.<sha256(conversation_id)[0,16]>` — bounded and safe
      # for the CLI's per-thread naming.
      def thread_id(surface_id, conversation_id)
        digest = ::Digest::SHA256.hexdigest("#{thread_domain}\n#{conversation_id}")[0, 16]
        "tg.#{surface_id}.#{digest}"
      end

      def thread_domain = 'tamoz.comms.thread.v1'

      def group_chat?(conversation_id)
        conversation_id.start_with?('telegram:supergroup:', 'telegram:channel:', 'telegram:group:')
      end

      def command_disposition(envelope, bot_username:)
        parsed = Commands.parse(envelope.fetch('text'), bot_username:)
        return Decision.new(:control, :unknown_command, 'Unknown command.', nil) if parsed.nil?

        Decision.new(:control, :command, nil, nil)
      end

      def text_disposition(envelope, surface:, binding:, conversation:)
        direct = surface.admission.fetch(:direct)
        case direct
        when 'allowlist'
          return request_disposition(envelope, surface:, conversation:) if binding&.fetch('status') == 'active'

          ignore(:unbound)
        when 'pairing'
          ignore(:pairing_pending)
        else
          reject(:disabled, 'admission is disabled')
        end
      end

      def request_disposition(envelope, surface:, conversation:)
        if conversation.nil?
          Decision.new(:request, :first_request, nil,
                       thread_id(surface.surface_id, envelope.fetch('conversation_id')))
        else
          Decision.new(:request, :bound, nil, conversation.fetch('thread_id'))
        end
      end

      def decision_disposition
        Decision.new(:decision, :callback, nil, nil)
      end

      def ignore(reason) = Decision.new(:ignored, reason, nil, nil)

      def reject(reason, reply)
        Decision.new(:rejected, reason, reply, nil)
      end
    end
  end
end
# rubocop:enable Metrics/PerceivedComplexity

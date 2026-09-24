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
      # The disposition of one update. `command_intent` is typed and bounded;
      # it is not task text and cannot be forwarded to a model.
      TEXT_ONLY_REPLY = 'I can only read text messages for now.'
      Decision = Data.define(
        :disposition, :reason, :control_reply, :thread_id, :command_intent
      )

      module_function

      def decide(envelope, surface:, binding: nil, conversation: nil, bot_username: nil)
        return reject(:surface_disabled, 'the surface is disabled') if surface.disabled?
        return unsupported(envelope, surface:, binding:) if envelope.fetch('kind') == 'unsupported'
        return ignore(:unsupported_kind) unless %w[text command callback].include?(envelope.fetch('kind'))
        return reject(:group_chat, 'group chats are refused in v1') if group_chat?(envelope.fetch('conversation_id'))
        return reject(:unbound, 'the correspondent is not bound') if binding && binding.fetch('status') != 'active'
        return callback_disposition if envelope.fetch('kind') == 'callback'

        if envelope.fetch('kind') == 'command'
          command_admission(envelope, surface:, binding:, bot_username:)
        else
          text_disposition(envelope, surface:, binding:, conversation:)
        end
      end

      # The deterministic per-conversation thread id (design §5):
      # `tg.<surface_id>.<sha256(conversation_id, generation)[0,16]>` —
      # bounded and safe for the CLI's per-thread naming. The generation
      # folds into the digest so `/new` rotates to a fresh thread without
      # deleting audit history (plan 02, work item 4); the domain is v2
      # because the digest input changed.
      def thread_id(surface_id, conversation_id, generation: 0)
        digest = ::Digest::SHA256.hexdigest("#{thread_domain}\n#{conversation_id}\n#{generation}")[0, 16]
        "tg.#{surface_id}.#{digest}"
      end

      def thread_domain = 'tamoz.comms.thread.v2'

      def group_chat?(conversation_id)
        conversation_id.start_with?('telegram:supergroup:', 'telegram:channel:', 'telegram:group:')
      end

      def command_admission(envelope, surface:, binding:, bot_username:)
        refusal = admission_refusal(envelope, surface:, binding:)
        return refusal if refusal

        command_disposition(envelope, bot_username:)
      end

      def command_disposition(envelope, bot_username:)
        parsed = Commands.parse(envelope.fetch('text'), bot_username:)
        return Decision.new(:control, :unknown_command, 'Unknown command.', nil, nil) if parsed.nil?

        Decision.new(:control, :command, nil, nil, parsed.intent)
      end

      def text_disposition(envelope, surface:, binding:, conversation:)
        admission_refusal(envelope, surface:, binding:) || request_disposition(envelope, surface:, conversation:)
      end

      # The configured allowlist IS the admission, and an approved pairing binding
      # is the dynamic operator addition to it; an empty allowlist admits nobody.
      def admission_refusal(envelope, surface:, binding:)
        direct = surface.admission.fetch(:direct)
        return reject(:disabled, 'admission is disabled') unless %w[allowlist pairing].include?(direct)
        return nil if authorized?(envelope, surface:, binding:)

        ignore(direct == 'pairing' ? :pairing_pending : :unbound)
      end

      def request_disposition(envelope, surface:, conversation:)
        if conversation.nil?
          Decision.new(:request, :first_request, nil,
                       thread_id(surface.surface_id, envelope.fetch('conversation_id')), nil)
        else
          Decision.new(:request, :bound, nil, conversation.fetch('thread_id'), nil)
        end
      end

      # A photo or sticker from someone allowed to talk gets told why nothing happens.
      def unsupported(envelope, surface:, binding:)
        conversation_id = envelope.fetch('conversation_id')
        return ignore(:unsupported_kind) if group_chat?(conversation_id) || !authorized?(envelope, surface:, binding:)

        Decision.new(:ignored, :unsupported_kind, TEXT_ONLY_REPLY, nil, nil)
      end

      def authorized?(envelope, surface:, binding:)
        active = binding&.fetch('status') == 'active'
        return active unless surface.admission.fetch(:direct) == 'allowlist'

        active || surface.admission.fetch(:correspondents).include?(envelope.fetch('correspondent_id'))
      end

      def callback_disposition
        Decision.new(:decision, :callback, nil, nil, nil)
      end

      def ignore(reason) = Decision.new(:ignored, reason, nil, nil, nil)

      def reject(reason, reply)
        Decision.new(:rejected, reason, reply, nil, nil)
      end
    end
  end
end
# rubocop:enable Metrics/PerceivedComplexity

# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Handles first-contact challenges and the read-only /start response.
      module Pairing
        private

        # `/start` is feedback only; binding activation stays with operator approval.
        def start_text(arguments)
          return START_USAGE_REPLY unless arguments

          START_PAIRED_REPLY
        end

        # Pairing first contact names one live challenge and reuses its plaintext
        # while the durable challenge remains pending.
        def handle_pairing_contact(envelope, now:)
          parsed = Comms::Commands.parse(envelope.fetch('text').to_s, bot_username:)
          if parsed&.command == 'start'
            append_control(pairing_start_reply(parsed.arguments, envelope, now:), envelope, now:)
            return
          end

          append_control("#{PAIRING_PENDING_REPLY}#{ensure_pairing_code(envelope, now:)}", envelope, now:)
        end

        def pairing_start_reply(code, envelope, now:)
          return START_USAGE_REPLY unless code

          matched = pending_pairing_rows(envelope, now).any? do |row|
            Comms::PairingChallenge.verify?(
              challenge: code, digest: row.fetch('challenge_digest'),
              surface_id: row.fetch('surface_id'), correspondent_id: row.fetch('correspondent_id'),
              conversation_id: row.fetch('conversation_id')
            )
          end
          matched ? START_WAITING_REPLY : START_NO_MATCH_REPLY
        end

        def pending_pairing_rows(envelope, now)
          @store.pairing_challenges(status: 'pending', surface_id:,
                                    correspondent_id: envelope.fetch('correspondent_id'), now:)
                .select { |row| row.fetch('conversation_id') == envelope.fetch('conversation_id') }
        end

        def ensure_pairing_code(envelope, now:)
          prune_issued_pairing_codes(now)
          reused = pending_pairing_rows(envelope, now).find do |row|
            row.fetch('conversation_id') == envelope.fetch('conversation_id') &&
              @issued_pairing_codes.key?(row.fetch('challenge_digest'))
          end
          return @issued_pairing_codes.fetch(reused.fetch('challenge_digest')) if reused

          issue_pairing_code(envelope, now:)
        end

        # The plaintext memo never outlives its durable rows, keeping it bounded
        # by the store's live pending challenge set.
        def prune_issued_pairing_codes(now)
          live = @store.pairing_challenges(status: 'pending', now:)
                       .map { |row| row.fetch('challenge_digest') }
          @issued_pairing_codes.delete_if { |digest, _code| !live.include?(digest) }
        end

        def issue_pairing_code(envelope, now:)
          code = Comms::PairingChallenge.generate_code
          correspondent_id = envelope.fetch('correspondent_id')
          challenge = Comms::PairingChallenge.build(
            surface_id:, correspondent_id:, conversation_id: envelope.fetch('conversation_id'),
            ttl_s: PAIRING_CODE_TTL_S, now:, code:
          )
          @store.insert_pairing_challenge(
            digest: challenge.digest, surface_id:, correspondent_id:,
            conversation_id: envelope.fetch('conversation_id'), expires_at: challenge.expires_at, now:
          )
          @issued_pairing_codes[challenge.digest] = code
          code
        end
      end
    end
  end
end

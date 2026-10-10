# frozen_string_literal: true

require 'json'
require 'time'

require_relative 'wire'

module Tamoz
  module SQLite
    # Row-shape helpers shared by the CommsStore collaborators (design §13). The
    # connection returns positional rows, so every SELECT names its column
    # list and every read zips columns onto the row.
    module CommsStoreRows
      DEFAULT_NAMESPACE = '[]'
      REQUEST_REF_WIDTH = 10
      REQUEST_REF_PATTERN = /\Ar[0-9a-f]{#{REQUEST_REF_WIDTH}}\z/

      # The connection's backend clock, for read projections whose age
      # arithmetic has no caller-bound `now:`; never Ruby wall-clock.
      BACKEND_TIME_SQL = <<~SQL.lines.map(&:strip).join(' ').freeze
        SELECT (
          CAST(strftime('%s', 'now') AS INTEGER) * 1000 +
          CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER)
        )
      SQL

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end

      def now_ms(now)
        raise ArgumentError, 'now must be a Time' unless now.is_a?(Time)

        (now.getutc.to_r * 1000).to_i
      end

      def backend_now_ms(txn, now)
        return now_ms(now) if now

        txn.scalar('comms.conversation.status.backend_time', BACKEND_TIME_SQL)
      end

      def encode_request(operation_text, delivery_text, payload)
        payload_bytes = @checkpoints.checkpoint_codec.dump_request_payload(operation_text, payload)
        payload_digest = Wire.digest(payload_bytes, domain: 'tamoz.sqlite.request_payload')
        input_digest = Wire.digest(JSON.generate([operation_text, delivery_text, payload_bytes]),
                                   domain: 'tamoz.sqlite.request')
        [payload_bytes, payload_digest, input_digest]
      end

      # The short non-authorizing display reference for one request (plan 02,
      # work item 2): `r` plus the first ten hex characters of the durable
      # request id. Uniqueness is the store's prefix resolution, never the
      # string's.
      def request_ref(request_id)
        "r#{request_id[0, REQUEST_REF_WIDTH]}"
      end

      # Invariant 57 capacity accounting (design §12): pending+claimed
      # JOURNALED rows (terminal answers, failures, prompts — the reserved
      # kinds) consume slots now; ephemeral accepted/status controls are
      # journaled=false and may be coalesced or dropped, so they do not pin
      # capacity. The reservations of admitted-but-unfinished requests consume
      # slots they are entitled to. Admission refuses when the new reservation
      # would exceed capacity, and a terminal append counts only the OTHER
      # requests' reservations — its own covers its rows, so the reserved
      # answer can always append.
      def pending_claimed_count(txn, surface_id)
        txn.scalar('comms.admit.capacity.outbox', <<~SQL, [surface_id]).to_i
          SELECT COUNT(*) FROM tamoz_comms_outbox
          WHERE surface_id = ? AND journaled = 1 AND status IN ('pending', 'claimed')
        SQL
      end

      def open_reservations(txn, surface_id)
        txn.scalar('comms.admit.capacity.requests', <<~SQL, [surface_id]).to_i
          SELECT COALESCE(SUM(reservation), 0) FROM tamoz_comms_requests
          WHERE surface_id = ? AND projection_state = 'admitted'
        SQL
      end

      def wire_time_ms(value)
        value && now_ms(Time.parse(value))
      end
    end
  end
end

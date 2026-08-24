# frozen_string_literal: true

module Tamoz
  module SQLite
    # Row-shape helpers shared by the CommsStore facade (design §13). The
    # connection returns positional rows, so every SELECT names its column
    # list and every read zips columns onto the row.
    #
    # The module is one shared SQL surface; the size and parameter-list
    # metrics measure the storage vocabulary, not a choice to overload.
    # rubocop:disable Metrics/ModuleLength, Metrics/ParameterLists
    module CommsStoreRows
      # SELECT column lists for the row-shaped reads; the connection returns
      # positional rows, so the zip order is the table's DDL order.
      SURFACE_COLUMNS = %w[
        surface_id revision definition_digest descriptor_json created_at_ms
        updated_at_ms
      ].freeze
      POLL_COLUMNS = %w[
        bot_id surface_id next_offset poller_owner_id poller_fence
        poller_expires_at_ms updated_at_ms
      ].freeze
      PAIRING_COLUMNS = %w[
        challenge_digest surface_id correspondent_id conversation_id status
        attempts expires_at_ms created_at_ms
      ].freeze
      PROMPT_COLUMNS = %w[
        reference_digest surface_id surface_revision thread_id occurrence_id
        interrupt_digest required_evidence correspondent_id conversation_id
        prompt_receipt status created_at_ms activated_at_ms consumed_at_ms
        expires_at_ms
      ].freeze
      BINDING_COLUMNS = %w[
        surface_id correspondent_id conversation_id status bound_by bound_at_ms
        version revocation_reason
      ].freeze
      ROUTE_COLUMNS = %w[
        surface_id conversation_id surface_revision thread_id profile_id
        threading bound_at_ms version
      ].freeze
      OUTBOX_COLUMNS = %w[
        delivery_id surface_id conversation_id kind operation text part_index
        part_count markup reply_to journaled content_digest render_version
        expires_at_ms status claim_owner claim_fence claim_expires_at_ms
        effect_key effect_execution_id receipt created_at_ms updated_at_ms
        send_started_at_ms
      ].freeze
      PACING_GLOBAL_SCOPE = '__global__'
      REQUEST_REF_WIDTH = 10
      REQUEST_REF_PATTERN = /\Ar[0-9a-f]{#{REQUEST_REF_WIDTH}}\z/.freeze

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

        (now.utc.to_r * 1000).to_i
      end

      def request_id_for(envelope_wire, bot_id)
        Tamoz::Core::RequestIdentity.request_id(
          surface_id: envelope_wire.fetch('surface_id'),
          surface_revision: envelope_wire.fetch('surface_revision'),
          bot_id:,
          update_id: envelope_wire.fetch('update_id'),
          raw_payload_hash: envelope_wire.fetch('raw_payload_hash')
        )
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

      def reservation_of(txn, request_id)
        txn.scalar('comms.admit.capacity.request', <<~SQL, [request_id]).to_i
          SELECT reservation FROM tamoz_comms_requests
          WHERE request_id = ? AND projection_state = 'admitted'
        SQL
      end

      # The ONE durable anchor row for an update identity (invariant 1): its
      # original payload digest plus the last conflicting digest seen and the
      # disposition those bytes currently carry.
      def inbound_anchor(txn, envelope_wire, bot_id)
        txn.first('comms.admit.inbound.anchor',
                  <<~SQL, [envelope_wire.fetch('surface_id'), bot_id, envelope_wire.fetch('update_id')])
                    SELECT raw_payload_hash, last_conflict_digest, disposition, reason
                    FROM tamoz_comms_inbound
                    WHERE surface_id = ? AND bot_id = ? AND update_id = ?
                    LIMIT 1
                  SQL
      end

      def open_request_count(txn, surface_id)
        txn.scalar('comms.admit.limit.open_requests', <<~SQL, [surface_id]).to_i
          SELECT COUNT(*) FROM tamoz_comms_requests
          WHERE surface_id = ? AND projection_state = 'admitted'
        SQL
      end

      # A disposition re-record dedups only on the FULL identity (digest
      # included), so a conflicting digest can still be recorded quarantined.
      def identical_inbound_row?(txn, envelope_wire, bot_id)
        hash = envelope_wire.fetch('raw_payload_hash')
        txn.first('comms.admit.inbound.identical',
                  <<~SQL, [envelope_wire.fetch('surface_id'), bot_id, envelope_wire.fetch('update_id'), hash])
                    SELECT 1 FROM tamoz_comms_inbound
                    WHERE surface_id = ? AND bot_id = ? AND update_id = ?
                      AND raw_payload_hash = ?
                  SQL
      end

      def insert_inbound!(txn, envelope_wire, bot_id:, disposition:, reason:, now:)
        txn.execute('comms.admit.inbound.insert',
                    <<~SQL, inbound_binds(envelope_wire, bot_id, disposition, reason, now))
                      INSERT INTO tamoz_comms_inbound (
                        surface_id, surface_revision, bot_id, update_id, raw_payload_hash,
                        parser_version, kind, correspondent_id, conversation_id,
                        disposition, reason, request_id, decision_id,
                        observed_at_ms, ingested_at_ms
                      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    SQL
      end

      # A conflicting observation never becomes a row of its own: it moves the
      # anchor's last_conflict_digest and counts once per DISTINCT conflicting
      # digest — redelivered identical conflicting bytes count exactly once.
      def record_inbound_conflict!(txn, envelope_wire, bot_id, disposition: nil, reason: nil)
        hash = envelope_wire.fetch('raw_payload_hash')
        binds = [hash, hash, disposition, reason,
                 envelope_wire.fetch('surface_id'), bot_id, envelope_wire.fetch('update_id')]
        txn.execute('comms.admit.inbound.conflict', <<~SQL, binds)
          UPDATE tamoz_comms_inbound
          SET conflict_count = conflict_count + CASE WHEN last_conflict_digest = ?
                THEN 0 ELSE 1 END,
              last_conflict_digest = ?,
              disposition = COALESCE(?, disposition),
              reason = COALESCE(?, reason)
          WHERE surface_id = ? AND bot_id = ? AND update_id = ?
        SQL
      end

      def inbound_binds(envelope_wire, bot_id, disposition, reason, now)
        [
          envelope_wire.fetch('surface_id'), envelope_wire.fetch('surface_revision'),
          bot_id, envelope_wire.fetch('update_id'),
          envelope_wire.fetch('raw_payload_hash'), envelope_wire.fetch('parser_version'),
          envelope_wire.fetch('kind'), envelope_wire.fetch('correspondent_id'),
          envelope_wire.fetch('conversation_id'), disposition, reason,
          envelope_wire['request_id'], envelope_wire['decision_id'],
          wire_time_ms(envelope_wire['observed_time']), now_ms(now)
        ]
      end

      def wire_time_ms(value)
        value && now_ms(Time.parse(value))
      end

      def prompt_binds(wire)
        [
          wire.fetch('reference_digest'), wire['surface_id'], wire['surface_revision'],
          wire.fetch('thread_id'), wire.fetch('occurrence_id'), wire.fetch('interrupt_digest'),
          wire.fetch('required_evidence'),
          wire.fetch('correspondent_id'), wire.fetch('conversation_id'), wire['prompt_receipt'],
          wire.fetch('status'), wire_time_ms(wire.fetch('created_at')),
          wire_time_ms(wire['activated_at']), wire_time_ms(wire['consumed_at']),
          wire_time_ms(wire.fetch('expires_at'))
        ]
      end

      def upsert_surface!(txn, descriptor_wire, now)
        binds = [descriptor_wire.fetch('surface_id'), descriptor_wire.fetch('revision'),
                 descriptor_wire.fetch('definition_digest'), JSON.generate(descriptor_wire),
                 now_ms(now), now_ms(now)]
        txn.execute('comms.surface.deploy.upsert', <<~SQL, binds)
          INSERT INTO tamoz_comms_surfaces (
            surface_id, revision, definition_digest, descriptor_json,
            created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(surface_id) DO UPDATE SET
            revision = excluded.revision,
            definition_digest = excluded.definition_digest,
            descriptor_json = excluded.descriptor_json,
            updated_at_ms = excluded.updated_at_ms
        SQL
      end

      def upsert_poller!(txn, surface_id:, bot_id:, owner:, fence:, expires_at_ms:, now:)
        txn.execute('comms.poll.lease.upsert', <<~SQL, [bot_id, surface_id, owner, fence, expires_at_ms, now_ms(now)])
          INSERT INTO tamoz_comms_poll_state (
            bot_id, surface_id, poller_owner_id, poller_fence,
            poller_expires_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(bot_id) DO UPDATE SET
            poller_owner_id = excluded.poller_owner_id,
            poller_fence = excluded.poller_fence,
            poller_expires_at_ms = excluded.poller_expires_at_ms,
            updated_at_ms = excluded.updated_at_ms
        SQL
      end

      def outbox_binds(delivery_wire, surface_id, now)
        [
          delivery_wire.fetch('delivery_id'), surface_id, delivery_wire.fetch('conversation_id'),
          delivery_wire.fetch('kind'), delivery_wire.fetch('operation'), delivery_wire.fetch('text'),
          delivery_wire.fetch('part_index'), delivery_wire.fetch('part_count'), delivery_wire['markup'],
          delivery_wire['reply_to'],
          delivery_wire.fetch('journaled') ? 1 : 0, delivery_wire.fetch('content_digest'),
          delivery_wire.fetch('render_version'),
          delivery_wire['expires_at'] && now_ms(Time.parse(delivery_wire['expires_at'])),
          now_ms(now), now_ms(now)
        ]
      end

      def binding_binds(binding_wire, _now)
        [
          binding_wire.fetch('surface_id'), binding_wire.fetch('correspondent_id'),
          binding_wire.fetch('conversation_id'), binding_wire.fetch('status'),
          binding_wire.fetch('bound_by'), now_ms(Time.parse(binding_wire.fetch('bound_at'))),
          binding_wire.fetch('version'), binding_wire['revocation_reason']
        ]
      end

      def route_binds(conversation_wire, _now)
        [
          conversation_wire.fetch('surface_id'), conversation_wire.fetch('conversation_id'),
          conversation_wire.fetch('surface_revision'), conversation_wire.fetch('thread_id'),
          conversation_wire.fetch('profile_id'), conversation_wire.fetch('threading'),
          now_ms(Time.parse(conversation_wire.fetch('bound_at'))), conversation_wire.fetch('version')
        ]
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength, Metrics/ParameterLists

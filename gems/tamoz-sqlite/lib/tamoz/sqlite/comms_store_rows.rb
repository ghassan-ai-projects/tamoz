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
      REQUEST_DOMAIN = 'tamoz.comms.request.v1'

      # SELECT column lists for the row-shaped reads; the connection returns
      # positional rows, so the zip order is the table's DDL order.
      PROMPT_COLUMNS = %w[
        reference_digest surface_id surface_revision thread_id occurrence_id
        interrupt_digest correspondent_id conversation_id prompt_receipt status
        created_at_ms activated_at_ms consumed_at_ms expires_at_ms
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
        part_count markup journaled content_digest render_version expires_at_ms
        status claim_owner claim_fence claim_expires_at_ms effect_key
        effect_execution_id receipt created_at_ms updated_at_ms
      ].freeze

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
        ::Digest::SHA256.hexdigest(
          "#{REQUEST_DOMAIN}\n" +
          JSON.generate([envelope_wire.fetch('surface_id'), envelope_wire.fetch('surface_revision'),
                         bot_id, envelope_wire.fetch('update_id'), envelope_wire.fetch('raw_payload_hash')])
        )
      end

      def inbound_row(txn, envelope_wire, bot_id)
        txn.first('comms.admit.inbound.existing',
                  <<~SQL, [envelope_wire.fetch('surface_id'), bot_id, envelope_wire.fetch('update_id')])
                    SELECT 1 FROM tamoz_comms_inbound
                    WHERE surface_id = ? AND bot_id = ? AND update_id = ?
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
          wire.fetch('correspondent_id'), wire.fetch('conversation_id'), wire['prompt_receipt'],
          wire.fetch('status'), wire_time_ms(wire.fetch('created_at')),
          wire_time_ms(wire['activated_at']), wire_time_ms(wire['consumed_at']),
          wire_time_ms(wire.fetch('expires_at'))
        ]
      end

      def upsert_surface!(txn, descriptor_wire, now)
        txn.execute('comms.surface.deploy.upsert',
                    <<~SQL, [descriptor_wire.fetch('surface_id'), descriptor_wire.fetch('revision'), descriptor_wire.fetch('definition_digest'), JSON.generate(descriptor_wire), now_ms(now), now_ms(now)])
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

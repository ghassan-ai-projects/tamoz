# frozen_string_literal: true

require 'time'

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Correspondent bindings and conversation routes (design §7, §13).
    # Bindings are versioned and revocable; a revocation atomically deletes
    # the correspondent's unused (inactive) approval prompts. A conversation
    # route is write-once per surface revision — a new profile or revision
    # rotates to a new thread generation instead of rewriting the binding.
    #
    # :reek:LongParameterList -- the primitives mirror the §13 contract
    #   signatures.
    class CommsRoutes
      include CommsStoreRows

      def initialize(adapter:)
        @adapter = adapter
      end

      def bind_correspondent(binding_wire, now:)
        transaction('comms.binding.bind') do |txn|
          bind_correspondent_in_transaction!(txn, binding_wire, now:)
        end
      end

      # The insert WITHOUT its own transaction, so `approve_pairing` can
      # consume the challenge and write the binding in one step (design §7).
      def bind_correspondent_in_transaction!(txn, binding_wire, now:)
        identity = [binding_wire.fetch('surface_id'), binding_wire.fetch('correspondent_id'),
                    binding_wire.fetch('version')]
        existing = txn.first('comms.binding.bind.existing', <<~SQL, identity)
          SELECT 1 FROM tamoz_comms_bindings
          WHERE surface_id = ? AND correspondent_id = ? AND version = ?
        SQL
        return :duplicate if existing

        txn.execute('comms.binding.bind', <<~SQL, binding_binds(binding_wire, now))
          INSERT INTO tamoz_comms_bindings (
            surface_id, correspondent_id, conversation_id, status,
            bound_by, bound_at_ms, version, revocation_reason
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        :bound
      end

      # Revoke one binding and atomically delete its unused (inactive) prompts.
      def revoke_binding(correspondent_id:, surface_id:, reason:, now:)
        transaction('comms.binding.revoke') do |txn|
          current = txn.first('comms.binding.revoke.current', <<~SQL, [surface_id, correspondent_id])
            SELECT version, status, conversation_id FROM tamoz_comms_bindings
            WHERE surface_id = ? AND correspondent_id = ?
            ORDER BY version DESC LIMIT 1
          SQL
          next :missing unless current
          next :revoked if current[1] == 'revoked'

          txn.execute('comms.binding.revoke',
                      <<~SQL, [surface_id, correspondent_id, current[2], now_ms(now), current[0] + 1, reason])
                        INSERT INTO tamoz_comms_bindings (
                          surface_id, correspondent_id, conversation_id, status,
                          bound_by, bound_at_ms, version, revocation_reason
                        ) VALUES (?, ?, ?, 'revoked', 'comms.gateway.revoke', ?, ?, ?)
                      SQL
          txn.execute('comms.binding.revoke.prompts', <<~SQL, [surface_id, correspondent_id])
            DELETE FROM tamoz_comms_approval_prompts
            WHERE surface_id = ? AND correspondent_id = ? AND status = 'inactive'
          SQL
          :revoked
        end
      end

      def binding(correspondent_id:, surface_id:, version: nil)
        read('comms.binding.read') do |txn|
          row = if version
                  txn.first('comms.binding.read.version', <<~SQL, [surface_id, correspondent_id, version])
                    SELECT #{BINDING_COLUMNS.join(', ')} FROM tamoz_comms_bindings
                    WHERE surface_id = ? AND correspondent_id = ? AND version = ?
                  SQL
                else
                  txn.first('comms.binding.read.latest', <<~SQL, [surface_id, correspondent_id])
                    SELECT #{BINDING_COLUMNS.join(', ')} FROM tamoz_comms_bindings
                    WHERE surface_id = ? AND correspondent_id = ?
                    ORDER BY version DESC LIMIT 1
                  SQL
                end
          row && BINDING_COLUMNS.zip(row).to_h
        end
      end

      def bind_conversation(conversation_wire, now:)
        transaction('comms.route.bind') do |txn|
          identity = [conversation_wire.fetch('surface_id'), conversation_wire.fetch('conversation_id')]
          existing = txn.first('comms.route.bind.existing', <<~SQL, identity)
            SELECT surface_revision FROM tamoz_comms_conversations
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          next :duplicate if existing && existing[0] >= conversation_wire.fetch('surface_revision')

          txn.execute('comms.route.bind', <<~SQL, route_binds(conversation_wire, now))
            INSERT INTO tamoz_comms_conversations (
              surface_id, conversation_id, surface_revision, thread_id,
              profile_id, threading, bound_at_ms, version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(surface_id, conversation_id) DO UPDATE SET
              surface_revision = excluded.surface_revision,
              thread_id = excluded.thread_id,
              profile_id = excluded.profile_id,
              bound_at_ms = excluded.bound_at_ms,
              version = excluded.version
          SQL
          :bound
        end
      end

      def conversation(surface_id:, conversation_id:)
        read('comms.route.read') do |txn|
          row = txn.first('comms.route.read', <<~SQL, [surface_id, conversation_id])
            SELECT #{ROUTE_COLUMNS.join(', ')} FROM tamoz_comms_conversations
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          row && ROUTE_COLUMNS.zip(row).to_h
        end
      end

      private

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end
    end
  end
end

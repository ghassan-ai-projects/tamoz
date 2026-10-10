# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # `tamoz comms pair revoke ID`: the binding goes on every deployed surface that has one, and the admitted work it
    # leaves behind is printed with the exact `tamoz cancel` commands.
    # :reek:FeatureEnvy, :reek:UtilityFunction
    module CLICommsRevoke
      private

      # Revokes the binding on every deployed surface that has one.
      def pair_revoke(options, correspondent_id)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          affected = store.surfaces.map { |row| row.fetch('surface_id') }.select do |surface_id|
            store.binding(correspondent_id:, surface_id:) &&
              store.revoke_binding(correspondent_id:, surface_id:, reason: 'operator revoke',
                                   now: Time.now.utc) == :revoked
          end
          next refuse("tamoz: no active binding for #{correspondent_id.inspect}") if affected.empty?

          print_revocation(correspondent_id, affected, revoked_threads(store, correspondent_id, affected), options)
          0
        end
      end

      def revoked_threads(store, correspondent_id, surfaces)
        surfaces.flat_map do |surface_id|
          store.bindings(surface_id:).select { |binding| binding.fetch('correspondent_id') == correspondent_id }
                                     .filter_map do |binding|
            current_generation_thread(
              store, surface_id, binding.fetch('conversation_id')
            )
          end
        end.uniq
      end

      def print_revocation(correspondent_id, affected, threads, options)
        return @out.puts(JSON.generate('revoked' => affected, 'threads' => threads)) if options[:json]

        @out.puts "revoked #{correspondent_id} on #{affected.join(', ')}"
        threads.each { |thread| @out.puts "admitted work on #{thread}: tamoz cancel #{thread}" }
      end

      # The thread the conversation admits onto NOW (its durable generation derives it, as admission and /cancel
      # do); an unbound conversation admits nothing.
      def current_generation_thread(store, surface_id, conversation_id)
        generation = store.conversation_generation(surface_id:, conversation_id:)
        Tamoz::Comms::Admission.thread_id(surface_id, conversation_id, generation:)
      rescue KeyError
        nil
      end
    end
  end
end

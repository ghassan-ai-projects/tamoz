# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # `tamoz comms pair list | approve CODE | revoke ID` — operator pairing and revocation (design §7).
    # Revocation prints the admitted work it leaves behind and the exact `tamoz cancel` commands, instead of hiding
    # several authority changes behind one flag.
    # :reek:FeatureEnvy, :reek:UtilityFunction, :reek:DuplicateMethodCall
    module CLICommsPairing
      include CLICommsRevoke

      def comms_pair(options, argv)
        case argv.shift
        when 'list' then pair_list(options, argv)
        when 'approve' then pair_approve(options, positional(argv, options, 'approve CODE').fetch(0))
        when 'revoke' then pair_revoke(options, positional(argv, options, 'revoke ID').fetch(0))
        else raise OptionParser::InvalidArgument, 'usage: tamoz comms pair list|approve CODE|revoke ID'
        end
      end

      private

      # The operands after the verb, each one required, then the shared --json flag.
      def positional(argv, options, usage)
        parser = OptionParser.new do |value|
          value.banner = "Usage: tamoz comms pair #{usage}"
          accept_json(value, options)
        end
        parser.order!(argv)
        names = usage.split.drop(1)
        operands = names.map { argv.shift }
        parser.parse!(argv)
        names.zip(operands).each { |name, value| raise OptionParser::MissingArgument, name if value.to_s.empty? }
        operands
      end

      def pair_list(options, argv)
        positional(argv, options, 'list')
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          pending = store.pairing_challenges(status: 'pending')
          active = store.surfaces.flat_map do |surface|
            store.bindings(surface_id: surface.fetch('surface_id')).select do |binding|
              binding.fetch('status') == 'active'
            end
          end
          print_pairings(pending, active, options)
        end
        0
      end

      def print_pairings(pending, active, options)
        return @out.puts(JSON.generate('pending_codes' => pending, 'bindings' => active)) if options[:json]
        return @out.puts('No pending pairing codes or active bindings.') if pending.empty? && active.empty?

        pending.each do |row|
          @out.puts "pending #{row.fetch('challenge_digest')[0, 12]} #{row.fetch('correspondent_id')} on " \
                    "#{row.fetch('surface_id')}"
        end
        active.each do |binding|
          @out.puts "active #{binding.fetch('correspondent_id')} #{binding.fetch('conversation_id')} " \
                    "bound_by=#{binding.fetch('bound_by')}"
        end
      end

      # The code is verified against the stored digest; consumption and the binding write are one transaction.
      def pair_approve(options, code)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          candidate = pending_challenge(store, code)
          next refuse('tamoz: no pending pairing code matches') unless candidate

          binding_wire = approved_binding(store, candidate)
          next refuse("tamoz: no surface deployed for #{candidate.fetch('surface_id').inspect}") unless binding_wire

          outcome = store.approve_pairing(challenge_digest: candidate.fetch('challenge_digest'), binding_wire:,
                                          now: Time.now.utc)
          next refuse('tamoz: pairing code was already consumed') unless outcome == :approved

          @out.puts options[:json] ? JSON.generate(binding_wire) : "paired #{binding_wire.fetch('correspondent_id')}"
          0
        end
      end

      def pending_challenge(store, code)
        store.pairing_challenges(status: 'pending').find do |row|
          Tamoz::Comms::PairingChallenge.verify?(
            challenge: code, **row.slice('surface_id', 'correspondent_id', 'conversation_id').transform_keys(&:to_sym),
            digest: row.fetch('challenge_digest')
          )
        end
      end

      # Bound under the deployed surface's revision; nil when the surface is not deployed.
      def approved_binding(store, candidate)
        surface = store.surface(surface_id: candidate.fetch('surface_id'))
        surface && Tamoz::Comms::Binding.new(
          surface_id: candidate.fetch('surface_id'),
          surface_revision: Tamoz::Comms::SurfaceDescriptor.from_wire(surface).revision,
          correspondent_id: candidate.fetch('correspondent_id'), conversation_id: candidate.fetch('conversation_id'),
          bound_at: Time.now.utc, bound_by: os_user_id
        ).wire
      end
    end
  end
end

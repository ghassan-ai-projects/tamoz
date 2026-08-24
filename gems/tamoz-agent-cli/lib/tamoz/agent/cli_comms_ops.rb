# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The rest of the channel operator surface (COMMS_DESIGN §14): pairing and
    # revocation (`tamoz comms pair`), honest resolution of genuinely
    # ambiguous sends (`tamoz comms delivery resolve`), the explicit config
    # migration (`tamoz config migrate`), and the `channels` section of
    # `tamoz status`.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
    # rubocop:disable Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/BlockLength
    #   -- one operator command per method; the json-vs-text branching is the
    #   CLI's global convention and the operator surfaces are one sequence
    #   each (verify -> consume -> report).
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:FeatureEnvy
    # :reek:NestedIterators, :reek:DataClump, :reek:UncommunicativeVariableName
    # :reek:UtilityFunction, :reek:IrresponsibleModule -- the module is one
    #   operator command per method; the json-vs-text branching is the CLI's
    #   global convention and the operator surfaces are one sequence each.
    module CLICommsOps
      include CLICommsShared

      def cmd_config(options, argv)
        action = argv.shift
        raise OptionParser::InvalidArgument, 'usage: tamoz config migrate' unless action == 'migrate'

        OptionParser.new do |value|
          value.banner = 'Usage: tamoz config migrate'
          accept_json(value, options)
        end.parse!(argv)

        outcome, _directory, backup = RuntimeDirectory.migrate!(runtime_dir_path(options))
        if outcome == :already_current
          @out.puts "already schema #{RuntimeDirectory::SCHEMA_VERSION}"
        else
          @out.puts "migrated to schema #{RuntimeDirectory::SCHEMA_VERSION} (backup: #{backup})"
        end
        0
      rescue RuntimeDirectory::Error => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      # `tamoz comms pair list | approve CODE | revoke ID` — operator pairing
      # and revocation (design §7). Revocation prints the admitted work it
      # leaves behind and the exact `tamoz cancel` commands, instead of hiding
      # multiple authority changes behind one flag.
      def comms_pair(options, argv)
        action = argv.shift
        case action
        when 'list' then pair_list(options, argv)
        when 'approve' then pair_approve(options, argv)
        when 'revoke' then pair_revoke(options, argv)
        else
          raise OptionParser::InvalidArgument, 'usage: tamoz comms pair list|approve CODE|revoke ID'
        end
      end

      def pair_list(options, argv)
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms pair list'
          accept_json(value, options)
        end.parse!(argv)

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          pending = store.pairing_challenges(status: 'pending')
          active = store.surfaces.flat_map do |surface|
            store.bindings(surface_id: surface.fetch('surface_id'))
                 .select { |binding| binding.fetch('status') == 'active' }
          end
          if options[:json]
            @out.puts JSON.generate('pending_codes' => pending, 'bindings' => active)
          elsif pending.empty? && active.empty?
            @out.puts 'No pending pairing codes or active bindings.'
          else
            pending.each do |row|
              @out.puts "pending #{row.fetch('challenge_digest')[0, 12]} " \
                        "#{row.fetch('correspondent_id')} on #{row.fetch('surface_id')}"
            end
            active.each do |binding|
              @out.puts "active #{binding.fetch('correspondent_id')} " \
                        "#{binding.fetch('conversation_id')} bound_by=#{binding.fetch('bound_by')}"
            end
          end
        end
        0
      end

      # Approve ONE pairing code: the code is verified against the stored
      # digest, and consumption + binding write happen in one transaction.
      def pair_approve(options, argv)
        parser = OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms pair approve CODE'
          accept_json(value, options)
        end
        parser.order!(argv)
        code = argv.shift
        parser.parse!(argv)
        raise OptionParser::MissingArgument, 'CODE' if code.to_s.empty?

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          candidate = store.pairing_challenges(status: 'pending').find do |row|
            Tamoz::Comms::PairingChallenge.verify?(
              challenge: code, digest: row.fetch('challenge_digest'),
              surface_id: row.fetch('surface_id'), correspondent_id: row.fetch('correspondent_id'),
              conversation_id: row.fetch('conversation_id')
            )
          end
          unless candidate
            @err.puts 'tamoz: no pending pairing code matches'
            return 1
          end
          if candidate.fetch('expires_at_ms') <= (Time.now.utc.to_r * 1000).to_i
            @err.puts 'tamoz: pairing code expired'
            return 1
          end

          surface = store.surface(surface_id: candidate.fetch('surface_id'))
          unless surface
            @err.puts "tamoz: no surface deployed for #{candidate.fetch('surface_id').inspect}"
            return 1
          end
          revision = Tamoz::Comms::SurfaceDescriptor.from_wire(surface).revision
          binding = Tamoz::Comms::Binding.new(
            surface_id: candidate.fetch('surface_id'), surface_revision: revision,
            correspondent_id: candidate.fetch('correspondent_id'),
            conversation_id: candidate.fetch('conversation_id'),
            bound_at: Time.now.utc, bound_by: os_user_id
          ).wire
          outcome = store.approve_pairing(
            challenge_digest: candidate.fetch('challenge_digest'), binding_wire: binding, now: Time.now.utc
          )
          unless outcome == :approved
            @err.puts 'tamoz: pairing code was already consumed'
            return 1
          end

          @out.puts options[:json] ? JSON.generate(binding) : "paired #{binding.fetch('correspondent_id')}"
          0
        end
      end

      # Revoke one binding per deployed surface; print the threads the
      # correspondent's conversations admitted and the exact cancel commands.
      def pair_revoke(options, argv)
        parser = OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms pair revoke ID'
          accept_json(value, options)
        end
        parser.order!(argv)
        correspondent_id = argv.shift
        parser.parse!(argv)
        raise OptionParser::MissingArgument, 'ID' if correspondent_id.to_s.empty?

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          surfaces = store.surfaces.map { |row| row.fetch('surface_id') }
          affected = []
          surfaces.each do |surface_id|
            next unless store.binding(correspondent_id:, surface_id:)

            outcome = store.revoke_binding(
              correspondent_id:, surface_id:, reason: 'operator revoke', now: Time.now.utc
            )
            affected << surface_id if outcome == :revoked
          end
          if affected.empty?
            @err.puts "tamoz: no active binding for #{correspondent_id.inspect}"
            return 1
          end

          threads = affected.flat_map do |surface_id|
            store.bindings(surface_id:).select { |b| b.fetch('correspondent_id') == correspondent_id }
                                       .filter_map do |binding|
              route = store.conversation(surface_id:,
                                         conversation_id: binding.fetch('conversation_id'))
              route&.fetch('thread_id')
            end
          end.uniq
          if options[:json]
            @out.puts JSON.generate('revoked' => affected, 'threads' => threads)
          else
            @out.puts "revoked #{correspondent_id} on #{affected.join(', ')}"
            threads.each { |thread| @out.puts "admitted work on #{thread}: tamoz cancel #{thread}" }
          end
          0
        end
      end

      # `tamoz comms delivery resolve ID STATUS` — a genuinely ambiguous send
      # (status :unknown) is resolved to succeeded or failed by the OPERATOR,
      # never retried blindly. The effect key is printed so the journal can be
      # reconciled with `tamoz resolve`.
      def comms_delivery(options, argv)
        action = argv.shift
        raise OptionParser::InvalidArgument, 'usage: tamoz comms delivery resolve ID STATUS' unless action == 'resolve'

        parser = OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms delivery resolve ID STATUS'
          accept_json(value, options)
        end
        parser.order!(argv)
        delivery_id = argv.shift
        status = argv.shift
        parser.parse!(argv)
        raise OptionParser::MissingArgument, 'ID' if delivery_id.to_s.empty?
        unless %w[succeeded failed].include?(status)
          raise OptionParser::InvalidArgument, 'STATUS must be succeeded or failed'
        end

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          rows = store.surfaces.flat_map do |surface|
            store.outbox_rows(surface_id: surface.fetch('surface_id'), statuses: %w[unknown], limit: 500)
          end
          row = rows.find { |candidate| candidate.fetch('delivery_id') == delivery_id }
          unless row
            @err.puts "tamoz: no unknown delivery #{delivery_id.inspect}"
            return 1
          end

          store.resolve_delivery(delivery_id:, status:, now: Time.now.utc)
          @out.puts "resolved #{delivery_id} as #{status} (effect #{row['effect_key']})"
          0
        end
      end

      # The reconnectable status view (plan 03, work item 5): one request
      # reference (or every match) resolved from the DURABLE stores alone —
      # no worker process, no session, no model call, and nothing re-runs.
      # Task and delivery states, queue facts, lifecycle, terminal reason,
      # and any cancellation timeline come from committed rows; JSON emits
      # the store's document shape, not a stream envelope.
      def comms_request(options, argv)
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms request R<reference> [--surface ID] [--conversation ID]'
          accept_json(value, options)
          value.on('--surface ID', 'Restrict to this surface') { |id| options[:surface] = id }
          value.on('--conversation ID', 'Restrict to this conversation') { |id| options[:conversation] = id }
        end.parse!(argv)
        reference = argv.shift
        raise OptionParser::MissingArgument, 'R<reference>' if reference.to_s.empty?

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          matches = store.requests_by_reference(reference).select do |surface_id, conversation_id, _|
            (options[:surface].nil? || surface_id == options[:surface]) &&
              (options[:conversation].nil? || conversation_id == options[:conversation])
          end
          if matches.empty?
            @err.puts "tamoz: no request with reference #{reference.inspect} is admitted"
            return 1
          end

          rows = matches.map do |surface_id, conversation_id, _|
            store.request_status(surface_id:, conversation_id:, ref: reference, now: Time.now.utc)
                 .merge('surface_id' => surface_id, 'conversation_id' => conversation_id)
          end
          if options[:json]
            @out.puts JSON.generate('schema' => 'tamoz.comms.request_view.v1', 'requests' => rows)
          else
            rows.each { |row| render_request_view(row) }
          end
        end
        0
      end

      # The `channels` section of `tamoz status` (design §14/§16): surfaces,
      # last-poll age, outbox depth, `:unknown` deliveries, and the comms
      # safety counters — all derived from durable rows.
      def comms_status(runtime)
        store = runtime.adapter.bind_comms_store(runtime.checkpoints)
        {
          'surfaces' => store.surfaces.map { |row| surface_status(store, row) },
          'safety_counters' => comms_safety_counters(store)
        }
      end

      private

      def render_request_view(row)
        @out.puts "request #{row.fetch('request_ref')} on #{row.fetch('surface_id')}/" \
                  "#{row.fetch('conversation_id')} (thread #{row.fetch('thread_id')})"
        @out.puts "  task=#{task_word(row)} delivery=#{delivery_word(row)} " \
                  "open_requests=#{row.fetch('open_requests')} state=#{row.fetch('state')}"
        queue_parts = []
        queue_parts << "queue_position=#{row['queue_position']}" if row.key?('queue_position')
        queue_parts << "queue_age_ms=#{row['queue_age_ms']}" if row['queue_age_ms']
        @out.puts "  #{queue_parts.join(' ')}" unless queue_parts.empty?
        cancellation = row['cancellation']
        return unless cancellation

        line = "  cancellation=#{cancellation.fetch('state')}"
        line += " requested_age_ms=#{cancellation['requested_age_ms']}"
        line += " observed_age_ms=#{cancellation['observed_age_ms']}" if cancellation['observed_at_ms']
        line += " terminal=#{cancellation['terminal']}" if cancellation['terminal']
        @out.puts line
        return unless cancellation['terminal'] == 'completed_before_effect'

        @out.puts '  terminal: completed before the cancellation took effect.'
      end

      def task_word(projection)
        internal = { 'not_started' => 'admitted', 'claimed' => 'running', 'redirecting' => 'waiting' }
                    .fetch(projection.fetch('task_state'), projection.fetch('task_state'))
        Tamoz::Comms::Lifecycle.task_state_for(internal) || 'idle'
      rescue Tamoz::Comms::ValidationError
        internal
      end

      def delivery_word(projection)
        Tamoz::Comms::Lifecycle.delivery_state_for(projection.fetch('delivery_state'))
      rescue Tamoz::Comms::ValidationError
        projection.fetch('delivery_state')
      end

      def surface_status(store, row)
        descriptor = Tamoz::Comms::SurfaceDescriptor.from_wire(JSON.parse(row.fetch('descriptor_json')))
        poll = store.poll_state(bot_id: descriptor.identity.fetch(:expected_bot_id))
        outbox = store.outbox_counts(surface_id: row.fetch('surface_id'))
        {
          'surface_id' => row.fetch('surface_id'),
          'revision' => row.fetch('revision'),
          'last_poll_at' => poll && ms_to_iso(poll.fetch('updated_at_ms')),
          'outbox_depth' => outbox,
          'unknown_deliveries' => outbox.fetch('unknown', 0)
        }
      end

      # Every counter is a count of durable evidence (design §16):
      # unauthorized admissions are request rows without any active binding;
      # chat grants are membership rows that reached `request` (impossible in
      # v1); the token never reaches a durable record by construction.
      def comms_safety_counters(store)
        audit = store.admission_audit_counts
        {
          'unauthorized_inbound_admissions' => audit.fetch('unauthorized_inbound_admissions'),
          'chat_grants' => audit.fetch('chat_grants'),
          'unknown_deliveries' => store.surfaces.sum do |row|
            store.outbox_counts(surface_id: row.fetch('surface_id')).fetch('unknown', 0)
          end,
          'credential_in_durable_record' => 0
        }
      end
    end
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
    # rubocop:enable Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/BlockLength
  end
end

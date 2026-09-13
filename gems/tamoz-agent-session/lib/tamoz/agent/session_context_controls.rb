# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'

module Tamoz
  module Agent
    # Typed context-control semantics at the session layer: /new /reset
    # /compact /usage /context /think /verbose. Every mutation commits exactly
    # one allowlisted `context_control` audit record through the fenced
    # checkpoint writer (the `Session#resolve_effect` seam) via
    # `Compiled#append_checkpoint`; the read-only controls open no writer.
    # Controls address one conversation generation: a managed thread id carries
    # the generation suffix (.gN), so post-/new operations naturally target the
    # successor thread while the old one stays fully readable.
    module SessionContextControls
      REASONING_DEPTHS = %w[low medium high].freeze
      ANSWER_VERBOSITIES = %w[quiet normal detailed].freeze

      # The episode working set /reset clears. Audit lives in checkpoint
      # history, the request inbox, and the effect journal — none of which a
      # reset touches.
      RESETTABLE_ARRAY_CHANNELS = %i[
        observations plan_versions plan_reviews approvals effect_intents
        effect_receipts seen_action_signatures seen_failure_signatures
        compactions adaptive_decisions adaptive_seen_actions
        behavior_transition_claim
      ].freeze
      RESETTABLE_NIL_CHANNELS = %i[accepted_plan verification blocked terminal route].freeze
      RESETTABLE_ZERO_CHANNELS = %i[step_cursor repair_attempt provider_ambiguity adaptive_iteration].freeze

      ContextControlProjection = Data.define(
        :control, :thread_id, :generation, :checkpoint_id, :sequence, :record
      ) do
        def document
          {
            'control' => control,
            'thread_id' => thread_id,
            'generation' => generation,
            'checkpoint_id' => checkpoint_id,
            'sequence' => sequence,
            'preferences' => record['preferences'],
            'truncated_fragments' => record['truncated_fragments'],
            'audit_digest' => SessionRecords.digest(record)
          }.compact
        end
      end

      UsageProjection = Data.define(:thread_id, :generation, :requests, :controls, :pinned_budgets,
                                    :observation_bytes, :lifecycle_events) do
        def document
          {
            'control' => 'usage',
            'thread_id' => thread_id,
            'generation' => generation,
            'requests' => requests,
            'controls' => controls,
            'pinned_budgets' => pinned_budgets,
            'observation_bytes' => observation_bytes,
            'lifecycle_events' => lifecycle_events
          }
        end
      end

      ContextProjection = Data.define(:thread_id, :generation, :preferences, :layers) do
        def document
          {
            'control' => 'context',
            'thread_id' => thread_id,
            'generation' => generation,
            'preferences' => preferences,
            'layers' => layers
          }
        end
      end

      CompactionToolbox = Struct.new(:catalog_digest, keyword_init: true)

      CompactionConfiguration = Struct.new(
        :model_call_safety, :model, :profile, :toolbox, :mcp, keyword_init: true
      )

      def generation_of(thread_id)
        match = /\A.+\.g(\d+)\z/.match(String(thread_id))
        return Integer(match[1]) if match

        1
      end

      def last_preference(controls, control_name, key)
        found = controls.reverse.find { |record| record.fetch('control') == control_name }
        found && found.dig('preferences', key)
      end

      # The cumulative durable-transcript prefix recorded by the latest
      # truncating control (/reset, /compact) never re-enters a later
      # model-visible frame.
      def visible_fragment_offset(controls)
        found = controls.reverse.find { |record| %w[reset compact].include?(record.fetch('control')) }
        found&.fetch('truncated_fragments', nil)
      end
      module_function :generation_of, :last_preference, :visible_fragment_offset

      # /reset — SAME generation, fresh episode state: clears the accumulated
      # prompt-context channels, records the durable-transcript prefix that
      # leaves the frame (cumulative, like /compact), keeps every prior turn
      # in durable audit history, and continues budget accounting untouched.
      def reset_episode(thread:, request_id:)
        fields = lambda do |source, _writer|
          total = conversation_history_for(thread).length
          {
            truncated_fragments: total,
            cleared_channels: resettable_channels(source.state)
          }
        end
        apply_control(thread:, request_id:, control: 'reset', fields:) do |candidate|
          RESETTABLE_ARRAY_CHANNELS.each { |channel| candidate[channel] = [] if candidate.key?(channel) }
          RESETTABLE_NIL_CHANNELS.each { |channel| candidate[channel] = nil if candidate.key?(channel) }
          RESETTABLE_ZERO_CHANNELS.each { |channel| candidate[channel] = 0 if candidate.key?(channel) }
          candidate[:next_node] = 'intake'
        end
      end

      # /think — per-generation reasoning-depth preference consumed by episode
      # construction through the planning-context frame's directives.
      def set_reasoning_depth(thread:, request_id:, depth:)
        value = validate_preference('reasoning_depth', depth, REASONING_DEPTHS)
        apply_control(thread:, request_id:, control: 'think',
                      fields: { preferences: { 'reasoning_depth' => value } })
      end

      # /verbose — per-generation answer verbosity consumed at composition and
      # verification rendering time through the planning-context frame.
      def set_answer_verbosity(thread:, request_id:, verbosity:)
        value = validate_preference('answer_verbosity', verbosity, ANSWER_VERBOSITIES)
        apply_control(thread:, request_id:, control: 'verbose',
                      fields: { preferences: { 'answer_verbosity' => value } })
      end

      # /compact — summarize-and-pin through the existing BoundedCompactor
      # envelope: verbose fragments are externalized behind verified digests
      # attributed as untrusted evidence, the compact frame plus summary
      # replaces them at composition time, authoritative facts stay in the
      # frame, and the event is audited with before/after digests. The summary
      # call is journaled (`SessionEffects#model_call`, stage :context_compact),
      # so a replay returns the recorded receipt.
      def compact_transcript(thread:, request_id:)
        guard_state!(thread)
        conversation = conversation_history_for(thread)
        fields = lambda do |source, writer|
          observations = verbose_input(source, conversation)
          before_digest = SessionRecords.digest('input' => observations)
          summarized = bounded_compaction(writer:, source:, observations:, request_id:)
          compact_fields(
            before_digest:, summarized:, fragment_count: conversation.length,
            pinned: pinned_reference(observations)
          )
        end
        apply_control(thread:, request_id:, control: 'compact', fields:)
      end

      # /usage — read-only projection of durable budget/accounting facts.
      # Token/cost rollups are not recorded at this layer and are reported as
      # absent rather than invented.
      def usage_report(thread:)
        state = read_control_state!(thread)
        UsageProjection.new(
          thread_id: String(thread),
          generation: generation_of(thread),
          requests: request_counts(app_for_thread(thread), thread),
          controls: control_counts(state),
          pinned_budgets: state.dig(:session, 'profile_budgets') || {},
          observation_bytes: {
            'used' => observation_bytes_used(state),
            'ceiling' => SessionNodes::MAX_OBSERVATION_BYTES
          },
          lifecycle_events: Array(state[:lifecycle_events]).length
        )
      end

      # /context — read-only projection of the current model-visible frame
      # composition: which layers are present and their sizes, never their raw
      # content.
      def context_report(thread:)
        state = read_control_state!(thread)
        controls = Array(state[:context_controls])
        session_record = state[:session].is_a?(Hash) ? state[:session] : {}
        total = conversation_history_for(thread).length
        ContextProjection.new(
          thread_id: String(thread),
          generation: generation_of(thread),
          preferences: active_preferences(controls),
          layers: {
            'skills' => {
              'skill_epoch' => session_record['skill_epoch'],
              'prompt_surface_digest' => session_record['prompt_surface_digest']
            }.compact,
            'memory' => memory_layer(session_record),
            'transcript' => transcript_layer(total, controls),
            'observations' => Array(state[:observations]).length,
            'compaction_records' => Array(state[:compactions]).length,
            'authoritative_keys' => authoritative_frame_keys(state)
          }
        )
      end

      private

      # The durable conversation history for `thread`, read through that thread's
      # own app checkpointer.
      def conversation_history_for(thread)
        SessionPlanningContext.conversation_history(
          app_for_thread(thread).checkpointer, thread_id: thread
        )
      end

      def validate_preference(name, value, allowed)
        unless value.is_a?(String) && allowed.include?(value)
          raise ArgumentError,
                "#{name} must be one of #{allowed.join(', ')} (got #{value.inspect})"
        end

        value
      end

      def control_owner(request_id)
        "tamoz.agent.session.control/#{request_id}"
      end

      def read_control_state!(thread)
        state = stored_state(thread)
        raise CheckpointConflictError, "thread #{thread} has no checkpoint" unless state

        state
      end

      def resettable_channels(state)
        (
          RESETTABLE_ARRAY_CHANNELS + RESETTABLE_NIL_CHANNELS + RESETTABLE_ZERO_CHANNELS
        ).select { |channel| state.key?(channel) }.map(&:to_s).sort
      end

      # One fenced transaction: read under the lock, decide, append exactly one
      # audit record, commit. `fields` may be a lambda resolved against the
      # locked source and writer so the record carries facts measured under
      # the same fence.
      def apply_control(thread:, request_id:, control:, fields: {})
        guard_state!(thread)
        app = app_for_thread(thread)
        checkpointer = app.checkpointer
        record = nil
        checkpoint = nil
        checkpointer.open_writer(
          thread_id: thread, namespace: [],
          owner_id: control_owner(request_id), ttl: checkpointer.writer_ttl
        ) do |writer|
          source = control_base(app, writer)
          base_state = source.state.to_h
          record = SessionRecords.build(
            'context_control',
            control:,
            thread_id: String(thread),
            request_id: String(request_id),
            generation: generation_of(thread),
            **(fields.respond_to?(:call) ? fields.call(source, writer) : fields)
          )
          candidate = base_state.merge(
            context_controls: Array(base_state[:context_controls]) + [record]
          )
          yield(candidate) if block_given?
          checkpoint = commit_control(writer, app, source, candidate)
        end
        ContextControlProjection.new(
          control:, thread_id: String(thread),
          generation: generation_of(thread), checkpoint_id: checkpoint.id,
          sequence: checkpoint.sequence, record:
        )
      end

      ControlBase = Struct.new(
        :id, :execution_id, :status, :logical_step, :frontier, :pending, :interrupts,
        :resume_values, :attempts, :failure, :total_tasks, :state, keyword_init: true
      )

      # A control may run before the first turn; it then starts the thread's
      # checkpoint chain over the graph's initial channels in a terminal status
      # so real turns still apply afterwards.
      def control_base(app, writer)
        source = writer.latest
        return source if source

        ControlBase.new(
          id: nil,
          execution_id: SecureRandom.uuid,
          status: :completed,
          logical_step: 0,
          frontier: [],
          pending: {},
          interrupts: [],
          resume_values: {},
          attempts: {},
          failure: nil,
          total_tasks: 0,
          state: app.state_manager.initial({}, remaining_steps: app.limits.max_steps)
        )
      end

      def commit_control(writer, app, source, candidate)
        app.append_checkpoint(
          writer:,
          expected_base_id: source.id,
          mode: source.id ? :advance : :start,
          execution_id: source.execution_id,
          state: candidate,
          status: source.status,
          logical_step: source.logical_step,
          frontier: source.frontier,
          pending: source.pending,
          interrupts: source.interrupts,
          resume_values: source.resume_values,
          attempts: source.attempts,
          failure: source.failure,
          total_tasks: source.total_tasks
        )
      end

      # The verbose model-visible history: conversation fragments plus the
      # episode's observation outputs, both bounded inputs to the compactor.
      def verbose_input(source, conversation)
        conversation.map do |fragment|
          compaction_entry("#{fragment.fetch('role')}: #{fragment.fetch('text')}",
                           'conversation_untrusted')
        end +
          Array(source.state[:observations]).map do |record|
            compaction_entry(record.fetch('output', ''), record.fetch('provenance', 'workspace'))
          end
      end

      def compaction_entry(output, provenance)
        { 'output' => output, 'provenance' => provenance, 'truncated' => false }
      end

      def bounded_compaction(writer:, source:, observations:, request_id:)
        compactor = SessionPlanningContext::BoundedCompactor.new(
          artifact_store: @artifact_store, tenant: @artifact_tenant
        )
        result = compactor.compact(context: {}, observations:, authoritative: authoritative_frame(source.state))
        return result unless result.compacted

        compactor.summarize(
          result, effects: SessionEffects.new(configuration: compaction_configuration),
                  durable_context: control_context(writer, source, request_id), phase: :read_only, iteration: 0
        )
      end

      def compact_fields(before_digest:, summarized:, fragment_count:, pinned:)
        fields = {
          before_digest:,
          after_digest: SessionRecords.digest('frame' => summarized.context),
          truncated_fragments: fragment_count,
          compaction_mode: summarized.record ? summarized.record.fetch('mode') : 'in_bounds'
        }
        summary_digest = summarized.record&.fetch('summary_digest', nil)
        if summary_digest
          fields[:summary] = summarized.record.fetch('summary')
          fields[:summary_digest] = summary_digest
        end
        fields[:artifact_refs] = [pinned] if pinned
        fields
      end

      # The exact pre-compact verbose input is externalized behind its verified
      # digest and attributed as untrusted evidence — the history stays
      # recoverable without ever re-entering the frame.
      def pinned_reference(observations)
        return nil unless @artifact_store
        return nil if observations.empty?

        raw = JSON.generate(observations.map { |entry| entry.fetch('output') })
        digest = "sha256:#{Digest::SHA256.hexdigest(raw)}"
        @artifact_store.retain(digest:, bytes: raw, media_type: 'text/plain')
        {
          'tenant' => @artifact_store.tenant,
          'digest' => digest,
          'byte_count' => raw.bytesize,
          'provenance' => 'conversation_untrusted'
        }
      end

      def compaction_configuration
        CompactionConfiguration.new(
          model_call_safety: :idempotent,
          model: @model,
          toolbox: CompactionToolbox.new(catalog_digest: @toolbox.catalog_digest)
        )
      end

      # The compact replay identity is the DETERMINISTIC control request id:
      # a replay of the same control request resolves to the same effect
      # logical identity and hits the recorded receipt instead of re-calling
      # the model.
      def control_context(writer, source, request_id)
        Tamoz::Context.new(
          run_id: "context.compact/#{request_id}",
          execution_id: source.execution_id,
          request_id: String(request_id),
          task_id: 'context.compact',
          effects: writer.effects
        )
      end

      def authoritative_frame(state)
        nodes_for_default_graph.authoritative_frame(state)
      end

      def authoritative_frame_keys(state)
        authoritative_frame(state).keys
      end

      def request_counts(app, thread)
        checkpointer = app.checkpointer
        return {} unless checkpointer.respond_to?(:request_history)

        checkpointer.request_history(thread_id: thread, namespace: [])
                    .group_by { |request| request.operation.to_s }
                    .transform_values(&:length)
      end

      def control_counts(state)
        Array(state[:context_controls]).each_with_object(Hash.new(0)) do |record, counts|
          counts[record.fetch('control')] += 1
        end
      end

      def observation_bytes_used(state)
        Array(state[:observations]).sum do |record|
          record.fetch('output_bytes') do
            record.fetch('output', '').bytesize
          end
        end
      end

      def active_preferences(controls)
        {
          'reasoning_depth' => SessionContextControls.last_preference(controls, 'think', 'reasoning_depth'),
          'answer_verbosity' => SessionContextControls.last_preference(controls, 'verbose', 'answer_verbosity')
        }.compact
      end

      def memory_layer(session_record)
        epoch = session_record['memory_epoch']
        epoch.is_a?(Hash) ? { 'layers' => epoch.fetch('layers', []) } : {}
      end

      def transcript_layer(total, controls)
        offset = SessionContextControls.visible_fragment_offset(controls) || 0
        {
          'fragments_total' => total,
          'fragments_visible' => total - offset,
          'truncated_by_control' => offset,
          'earlier_summary_pinned' => summary_pinned?(controls)
        }
      end

      def summary_pinned?(controls)
        controls.any? { |record| record['control'] == 'compact' && record.key?('summary_digest') }
      end
    end
  end
end

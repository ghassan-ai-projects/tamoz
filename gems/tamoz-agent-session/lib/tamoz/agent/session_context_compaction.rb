# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    module SessionContextControls
      # /compact: summarize-and-pin through the BoundedCompactor envelope.
      module CompactControl
        CompactionToolbox = Struct.new(:catalog_digest, keyword_init: true)

        CompactionConfiguration = Struct.new(
          :model_call_safety, :model, :profile, :toolbox, :mcp, keyword_init: true
        )

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

        private

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
      end
    end
  end
end

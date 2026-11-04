# frozen_string_literal: true

module Tamoz
  module Agent
    module SessionContextControls
      # /context: the read-only projection of the current model-visible frame composition.
      module ContextReport
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

        # /context — read-only projection of the current model-visible frame
        # composition: which layers are present and their sizes, never their raw
        # content.
        def context_report(thread:)
          state = read_control_state!(thread)
          controls = Array(state[:context_controls])
          total = conversation_history_for(thread).length
          ContextProjection.new(
            thread_id: String(thread),
            generation: generation_of(thread),
            preferences: active_preferences(controls),
            layers: context_layers(state, controls, total)
          )
        end

        private

        def context_layers(state, controls, total)
          session_record = state[:session].is_a?(Hash) ? state[:session] : {}
          {
            'skills' => skills_layer(session_record),
            'memory' => memory_layer(session_record),
            'transcript' => transcript_layer(total, controls),
            'observations' => Array(state[:observations]).length,
            'compaction_records' => Array(state[:compactions]).length,
            'authoritative_keys' => authoritative_frame(state).keys
          }
        end

        def skills_layer(session_record)
          {
            'skill_epoch' => session_record['skill_epoch'],
            'prompt_surface_digest' => session_record['prompt_surface_digest']
          }.compact
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
end

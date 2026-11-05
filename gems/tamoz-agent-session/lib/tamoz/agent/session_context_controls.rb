# frozen_string_literal: true

require_relative 'session_context_fence'
require_relative 'session_context_compaction'
require_relative 'session_context_usage'
require_relative 'session_context_report'

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
      include Fence
      include CompactControl
      include UsageReport
      include ContextReport

      REASONING_DEPTHS = %w[low medium high].freeze
      TRUNCATING_CONTROLS = %w[reset compact].freeze
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

      def generation_of(thread_id)
        match = /\A.+\.g(\d+)\z/.match(String(thread_id))
        return Integer(match[1]) if match

        1
      end

      def last_preference(controls, control_name, key)
        found = controls.reverse.find { |record| record.fetch('control') == control_name }
        found&.dig('preferences', key)
      end

      # The cumulative durable-transcript prefix recorded by the latest
      # truncating control (/reset, /compact) never re-enters a later
      # model-visible frame.
      def visible_fragment_offset(controls)
        found = controls.reverse.find { |record| TRUNCATING_CONTROLS.include?(record.fetch('control')) }
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
          clear_episode_channels(candidate)
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

      private

      def validate_preference(name, value, allowed)
        unless value.is_a?(String) && allowed.include?(value)
          raise ArgumentError,
                "#{name} must be one of #{allowed.join(', ')} (got #{value.inspect})"
        end

        value
      end

      def resettable_channels(state)
        (
          RESETTABLE_ARRAY_CHANNELS + RESETTABLE_NIL_CHANNELS + RESETTABLE_ZERO_CHANNELS
        ).select { |channel| state.key?(channel) }.map(&:to_s).sort
      end

      def clear_episode_channels(candidate)
        RESETTABLE_ARRAY_CHANNELS.each { |channel| candidate[channel] = [] if candidate.key?(channel) }
        RESETTABLE_NIL_CHANNELS.each { |channel| candidate[channel] = nil if candidate.key?(channel) }
        RESETTABLE_ZERO_CHANNELS.each { |channel| candidate[channel] = 0 if candidate.key?(channel) }
        candidate[:next_node] = 'intake'
      end
    end
  end
end

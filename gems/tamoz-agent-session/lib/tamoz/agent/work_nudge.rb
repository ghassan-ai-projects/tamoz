# frozen_string_literal: true

module Tamoz
  module Agent
    # The one note a turn may get suggesting delegation: after it has read `nudge_reads` distinct files, or its surface
    # has grown to `nudge_window` of the compaction threshold, without delegating. Appended once, never rewriting an
    # earlier message, and only when `delegate` is offered.
    # :reek:TooManyStatements :reek:UtilityFunction
    # One predicate over the turn's state; the thresholds are shipped data.
    class WorkNudge
      SOURCE = 'delegate_nudge'

      def initialize(work:)
        @work = work
      end

      def entry(state)
        entries = state.fetch(:work_entries)
        return nil unless due?(state, entries)

        @work.entry(entries, 'system_update', Harness::PromptPack.fetch('delegate_nudge'), source: SOURCE)
      end

      private

      def due?(state, entries)
        return false unless @work.header.tool_names.include?('delegate')
        return false if entries.any? { |entry| entry['source'] == SOURCE }
        return false if state.fetch(:work_trace).any? { |event| event['event'] == 'subagent_started' }

        read_many?(state) || window_filling?(state, entries)
      end

      def roles = Harness::SubagentRoles.shipped

      def read_many?(state)
        Hash(state[:work_observations]).count { |_, seen| seen['read'] } >= roles.nudge_reads
      end

      # What this turn added since its pinned opening (transcript, guidance, memory), not the whole surface.
      def window_filling?(state, entries)
        threshold = @work.settings.context_policy.threshold_tokens(@work.window)
        calibration = state[:work_series]&.fetch('calibration', nil)
        opening = @work.estimate(entries.select { |entry| entry['pinned'] }, calibration)
        grown = @work.estimate(entries, calibration) - opening
        grown >= threshold * roles.nudge_window
      end
    end
  end
end

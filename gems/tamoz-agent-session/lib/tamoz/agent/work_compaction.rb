# frozen_string_literal: true

module Tamoz
  module Agent
    # Keeps a work turn inside its window: prune first, compact at a boundary, and on the next
    # pressure event reset to a handoff note instead of compacting a summary again.
    class WorkCompaction
      MAX_RESETS = 2

      def initialize(services:, work:)
        @services = services
        @work = work
      end

      def reduce(state, context, forced:)
        entries = state.fetch(:work_entries)
        policy = @work.settings.context_policy
        window = @work.window
        return {} unless forced || @work.estimate(entries, calibration(state)) >= policy.threshold_tokens(window)

        pruned = prune(entries, policy, window, forced)
        after = entries + pruned
        return replacement_update(pruned, 'prune') unless forced || compact_now?(state, after, policy, window)

        escalate(state, context, after, pruned, forced)
      end

      private

      def compact_now?(state, entries, policy, window)
        estimate = @work.estimate(entries, calibration(state))
        estimate >= policy.threshold_tokens(window) &&
          (state[:work_boundary] || estimate >= policy.backstop_tokens(window))
      end

      def calibration(state) = state[:work_series]&.fetch('calibration', nil)

      def retain_tokens(policy, window,
                        forced)
        forced ? policy.retain_tokens(window) / 2 : policy.retain_tokens(window)
      end

      def prune(entries, policy, window, forced)
        selection = ContextEngine::Compaction.select(entries, retain_tokens: retain_tokens(policy, window, forced),
                                                              resolve: @work.resolve)
        return [] unless selection

        ContextEngine::Pruner.prune(entries, store: @work.store, resolve: @work.resolve,
                                             before_seq: selection.last_seq + 1, budget: policy.prune_budget)
                             .map(&:entry)
      end

      def escalate(state, context, entries, pruned, forced)
        policy = @work.settings.context_policy
        if state.fetch(:work_compactions) >= policy.max_compactions_per_turn
          return reset(state, entries, pruned, 'context pressure after a compaction')
        end

        compact(state, context, entries, pruned, retain_tokens(policy, @work.window, forced))
      end

      # rubocop:disable Metrics/AbcSize -- summary, checkpoint and plan re-read are one replacement
      def compact(state, context, entries, pruned, retain)
        selection = ContextEngine::Compaction.select(entries, retain_tokens: retain, resolve: @work.resolve)
        return replacement_update(pruned, 'prune') unless selection

        summary = summarize(state, context, entries, selection)
        checkpoint = ContextEngine::Compaction.checkpoint_entry(summary, selection:, entries:, store: @work.store)
        checkpointed = with_plan_reread(state, entries + [checkpoint])
        combine(replacement_update(pruned, 'prune'), replacement_update(checkpointed - entries, 'compaction'))
          .merge(work_compactions: state.fetch(:work_compactions) + 1, work_series: declared(state))
      rescue ContextEngine::InvalidSummaryError, SummaryUnavailable => e
        combine(replacement_update(pruned, 'prune'),
                { work_trace: [{ 'event' => 'compaction_fallback', 'reason' => e.message }] })
          .merge(work_compactions: state.fetch(:work_compactions) + 1)
      end
      # rubocop:enable Metrics/AbcSize

      # The summary could not be produced; the loop continues on the pruned surface.
      class SummaryUnavailable < StandardError; end

      def summarize(state, context, entries, selection)
        messages = ContextEngine::Compaction.summary_messages(entries, header: @work.header, selection:,
                                                                       resolve: @work.resolve)
        call = @services.effects.converse(context, stage: :work_compact, messages:, tools: @work.header.tools,
                                                   iteration: state.fetch(:work_step_count),
                                                   tool_choice: 'none')
        raise SummaryUnavailable, "summary call ended #{call.status}" unless call.status == :succeeded

        ContextEngine::Compaction.validate!(
          call.value.fetch('content'), source_bytes: selection.source_bytes(@work.resolve),
                                       required_strings: ContextEngine::Compaction.required_strings(
                                         selection, tools: WorkContext::MUTATING_TOOLS, resolve: @work.resolve
                                       )
        )
      end

      def reset(state, entries, pruned, reason)
        resets = state.fetch(:work_resets)
        return exhausted_update(pruned) if resets >= MAX_RESETS

        selection = ContextEngine::Compaction.select(entries, retain_tokens: 0, resolve: @work.resolve)
        return replacement_update(pruned, 'prune') unless selection

        note = Harness::Handoff.note(plan: plan(state), reason:, task: state.fetch(:task))
        entry = @work.entry(entries, 'checkpoint', note, replaces: [selection.first_seq, selection.last_seq],
                                                         source: 'reset')
        combine(replacement_update(pruned, 'prune'), replacement_update([entry], 'reset'))
          .merge(work_resets: resets + 1, work_series: declared(state))
      end

      def with_plan_reread(state, entries)
        current = plan(state)
        return entries unless current

        @work.append(entries, 'user', "#{Harness::PromptPack.fetch('plan_reread')}\n\n#{current.render}")
      end

      def plan(state) = state[:work_plan] && Harness::PlanDocument.new(state.fetch(:work_plan).fetch('document'))

      def declared(state) = (state[:work_series] || {}).merge('declared' => true, 'calibration' => nil)

      def replacement_update(entries, reason)
        return {} if entries.empty?

        { work_entries: entries,
          work_trace: [{ 'event' => 'replacement', 'reason' => reason, 'entries' => entries.length }] }
      end

      def combine(first, second)
        first.merge(second) { |_, left, right| left + right }
      end

      def exhausted_update(pruned)
        replacement_update(pruned, 'prune').merge(work_exhausted: 'context pressure after two resets')
      end
    end
  end
end

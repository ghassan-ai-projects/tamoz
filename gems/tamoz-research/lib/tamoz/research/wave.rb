# frozen_string_literal: true

module Tamoz
  module Research
    # One wave of research children: which sub-questions each child takes, its objective and boundaries, and the
    # searches and page reads it may spend.
    # :reek:FeatureEnvy :reek:LongParameterList :reek:TooManyStatements -- it checks an assignment against the
    # ledger's spend and renders it.
    class Wave
      # What one child is given: its sub-question ids, objective, boundaries, source hints and budget.
      Assignment = Data.define(:sub_question_ids, :objective, :boundaries, :source_hints, :searches, :page_reads)

      attr_reader :assignments

      # The ledger says which sub-questions are open and what the run has spent.
      def self.parse(arguments, ledger:, depth:, budgets:)
        items = arguments.is_a?(Hash) ? arguments['assignments'] : nil
        used = ledger.used
        refuse_count(items, depth, budgets, used)
        seen = []
        drafts = items.map { |item| draft(item, ledger.open_ids, seen) }
        allotted = allot(drafts.length, depth, used)
        new(ledger.brief, drafts.map { |fields| Assignment.new(**fields, **allotted) })
      end

      def self.refuse_count(items, depth, budgets, used)
        per_wave = depth.children_per_wave
        count = items.is_a?(Array) ? items.length : 0
        raise Error, "assignments must list 1 to #{per_wave} children" unless count.between?(1, per_wave)

        waves = depth.waves
        raise Error, "the run has used its #{waves} waves; write the report" if used.fetch('waves') >= waves

        left = budgets.ceilings.fetch('children_per_run') - used.fetch('children')
        raise Error, "only #{left} more children fit this run" if count > left
      end

      def self.draft(item, open_ids, seen)
        raise Error, 'each assignment must be an object' unless item.is_a?(Hash)

        ids = item['sub_questions']
        raise Error, 'each assignment names 1 to 4 sub-question ids' unless
          ids.is_a?(Array) && ids.length.between?(1, 4) && ids.all?(String)

        claimed(ids, open_ids, seen)
        { sub_question_ids: ids.dup.freeze, objective: Text.bounded(item['objective'], 'objective', max: 600),
          boundaries: Text.bounded(item.fetch('boundaries', 'none'), 'boundaries', max: 400),
          source_hints: Text.bounded(item.fetch('source_hints', 'none'), 'source_hints', max: 300) }
      end

      def self.claimed(ids, open_ids, seen)
        closed = ids - open_ids
        raise Error, "#{closed.join(', ')} is not an open sub-question" unless closed.empty?

        repeated = ids & seen
        raise Error, "#{repeated.join(', ')} is assigned twice in one wave" unless repeated.empty?

        seen.concat(ids)
      end

      # This wave's share of what is left, split between its children: later waves keep theirs.
      def self.allot(children, depth, used)
        waves_left = depth.waves - used.fetch('waves')
        %w[searches page_reads].to_h do |key|
          left = depth.public_send(key) - used.fetch(key)
          raise Error, "the run has spent its #{key.tr('_', ' ')}; write the report" if left < children

          [key.to_sym, [left / waves_left / children, 1].max]
        end
      end

      private_class_method :refuse_count, :draft, :claimed, :allot

      def initialize(brief, assignments)
        @brief = brief
        @assignments = assignments.freeze
        freeze
      end

      # The child's whole task: it cannot see the plan, the conversation or its siblings.
      def child_task(assignment)
        lines = ["Research task. The overall question, for context only: #{@brief.question}", '',
                 'Your sub-questions:']
        lines += assignment.sub_question_ids.map do |id|
          sub = @brief.fetch(id)
          "- #{id}: #{sub.text} Look at it as #{sub.perspective}."
        end
        (lines + ['', "Objective: #{assignment.objective}", "Stay out of: #{assignment.boundaries}",
                  "Source hints: #{assignment.source_hints}",
                  "Budget: at most #{assignment.searches} searches and #{assignment.page_reads} page reads.",
                  'Finish with report_sources.']).join("\n")
      end
    end
  end
end

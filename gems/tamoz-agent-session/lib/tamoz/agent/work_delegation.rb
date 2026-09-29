# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # The `delegate` tool: admits one brief or a fan-out of briefs, runs one child graph per brief (concurrently for a
    # fan-out), and returns one bounded tool result with a section per child plus their trace events.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList :reek:NilCheck :reek:TooManyStatements
    # :reek:UtilityFunction
    # Admission rules and the result layout are one contract over the tool's arguments; they read no other state.
    class WorkDelegation
      MAX_BRIEF_BYTES = 4096
      ANSWER_BYTES = 4096
      NO_CHANGE = 'a review reads a change, and there is no change in this turn yet'

      # What one admitted call will run: the briefs as the children get them, the fan-out's batch id, the changed paths
      # a review is handed, and each answer's byte budget.
      Plan = Data.define(:briefs, :batch, :changed, :budget)

      def initialize(services:, work:)
        @services = services
        @work = work
      end

      def call(state, context, call)
        child, plan, refusal = admitted(state, call.arguments, call.id)
        return WorkTools::Outcome.new(text: "Error: #{refusal}", update: {}) if refusal

        reports, duration_ms = run(child, plan.briefs, context)
        trace = events(reports, plan, duration_ms)
        WorkTools::Outcome.new(text: text(reports, plan.budget), update: { work_trace: trace })
      end

      private

      def run(child, briefs, context)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inputs = briefs.map { |brief| { task: brief } }
        outputs = inputs.length == 1 ? [child.app.call(inputs.first, context)] : child.app.call_many(inputs, context)
        reports = outputs.map do |output|
          SubagentReport.new(role: child.role.name, output:, store: @work.store, scrub: @work.method(:scrub))
        end
        [reports, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).to_i]
      end

      def text(reports, budget)
        sections = reports.map { |report| report.render(budget) }
        reports.length == 1 ? sections.first : (["Fan-out: #{reports.length} subagents"] + sections).join("\n\n")
      end

      def events(reports, plan, duration_ms)
        reports.zip(plan.briefs).flat_map do |report, brief|
          started = { 'event' => 'subagent_started', 'role' => report.role,
                      'brief_digest' => "sha256:#{Digest::SHA256.hexdigest(brief)}",
                      'execution_id' => report.output.fetch(:work_execution_id), 'batch' => plan.batch,
                      'changed' => plan.changed }.compact
          [started, report.finished_event(duration_ms, plan.budget)]
        end
      end

      def admitted(state, arguments, call_id)
        apps = @services.configuration.subagent_apps
        child = apps[arguments['role']]
        return [nil, nil, "unknown subagent role; one of #{apps.keys.join(', ')}"] unless child

        briefs, refusal = briefs_of(arguments)
        refusal ||= brief_problem(state, briefs)
        changed = changed_paths(child, state)
        refusal ||= NO_CHANGE if changed&.empty?
        [child, refusal ? nil : plan(briefs, changed, call_id), refusal]
      end

      # A reviewing role is handed what the parent changed, from the turn's record; other roles are handed nothing.
      def changed_paths(child, state) = (Array(state[:work_changes]).uniq if child.role.reviews_changes?)

      def brief_problem(state, briefs)
        briefs.filter_map { |brief| invalid_brief(brief) }.first || over_cap(state, briefs.length)
      end

      def plan(briefs, changed, call_id)
        briefs = briefs.map { |brief| "#{brief}\n\nFiles changed in this turn: #{changed.join(', ')}" } if changed
        Plan.new(briefs:, batch: briefs.length > 1 ? call_id : nil, changed:, budget: ANSWER_BYTES / briefs.length)
      end

      def briefs_of(arguments)
        single = arguments.key?('brief')
        many = arguments['briefs']
        return [nil, 'give exactly one of brief or briefs'] if single == !many.nil?
        return [[arguments['brief']], nil] if single

        limit = Harness::SubagentRoles.shipped.max_fanout
        return [many, nil] if many.is_a?(Array) && many.length.between?(2, limit)

        [nil, "briefs must be a list of 2 to #{limit} briefs"]
      end

      def invalid_brief(brief)
        return 'each brief must be a non-empty string' unless brief.is_a?(String) && !brief.strip.empty?
        return "a brief exceeds #{MAX_BRIEF_BYTES} bytes" if brief.bytesize > MAX_BRIEF_BYTES
        return 'a brief contains a credential-shaped value' if Core.secret_shaped?(brief)

        nil
      end

      def over_cap(state, wanted)
        cap = Harness::SubagentRoles.shipped.max_per_turn
        started = state.fetch(:work_trace).count { |event| event['event'] == 'subagent_started' }
        "subagent limit reached (#{cap} per turn); #{[cap - started, 0].max} left" if started + wanted > cap
      end
    end
  end
end

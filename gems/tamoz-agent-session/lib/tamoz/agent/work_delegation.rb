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

      def initialize(services:, work:)
        @services = services
        @work = work
      end

      def call(state, context, call)
        child, briefs, refusal = admitted(state, call.arguments)
        return WorkTools::Outcome.new(text: "Error: #{refusal}", update: {}) if refusal

        reports, duration_ms = run(child, briefs, context)
        budget = ANSWER_BYTES / briefs.length
        batch = briefs.length > 1 ? call.id : nil
        WorkTools::Outcome.new(text: text(reports, budget),
                               update: { work_trace: events(reports, briefs, batch, duration_ms, budget) })
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

      def events(reports, briefs, batch, duration_ms, budget)
        reports.zip(briefs).flat_map do |report, brief|
          started = { 'event' => 'subagent_started', 'role' => report.role,
                      'brief_digest' => "sha256:#{Digest::SHA256.hexdigest(brief)}",
                      'execution_id' => report.output.fetch(:work_execution_id), 'batch' => batch }.compact
          [started, report.finished_event(duration_ms, budget)]
        end
      end

      def admitted(state, arguments)
        apps = @services.configuration.subagent_apps
        child = apps[arguments['role']]
        return [nil, nil, "unknown subagent role; one of #{apps.keys.join(', ')}"] unless child

        briefs, refusal = briefs_of(arguments)
        refusal ||= briefs.filter_map { |brief| invalid_brief(brief) }.first || over_cap(state, briefs.length)
        [child, briefs, refusal]
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

# frozen_string_literal: true

module Tamoz
  module Agent
    # `tamoz schedule` — the operator's view of recurring work.
    #
    # A schedule is a standing instruction to enqueue a task. It does not execute
    # anything itself; the worker materializes due occurrences into the ordinary
    # request inbox and then treats them exactly like queued work. That is the
    # point: there is one execution path, and scheduling is a way of putting work
    # on it rather than a second way of running work.
    module CLIScheduleCommands
      SCHEDULE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_\-.]{0,63}\z/

      # Where a schedule's task text lives. The `payload_ref` on the schedule is a
      # content digest; this is the content it addresses. It is kept in the
      # operator's runtime database — never in the workspace — so a checkout the
      # agent can write to cannot rewrite what a schedule will ask for.
      SCHEDULE_PAYLOADS = %w[tamoz scheduler payload].freeze

      def cmd_schedule(options, argv)
        action = argv.shift
        case action
        when "add" then schedule_add(options, argv)
        when "list" then schedule_list(options, argv)
        when "show" then schedule_show(options, argv)
        when "pause" then schedule_set_enabled(options, argv, enabled: false)
        when "resume" then schedule_set_enabled(options, argv, enabled: true)
        when "remove", "rm" then schedule_remove(options, argv)
        when "run-now", "run_now" then schedule_run_now(options, argv)
        when "occurrences", "history" then schedule_occurrences(options, argv)
        else
          raise OptionParser::InvalidArgument,
                "usage: tamoz schedule add|list|show|pause|resume|remove|run-now|occurrences"
        end
      end

      # `tamoz schedule add --id ID (--interval SECONDS | --at TIME) --task TASK`
      def schedule_add(options, argv)
        id = nil
        interval = nil
        at = nil
        task = nil
        profile_id = nil
        thread = nil
        max_steps = nil
        max_wall_seconds = nil
        OptionParser.new do |value|
          value.banner = "Usage: tamoz schedule add --id ID (--interval SECONDS | --at TIME) --task TASK"
          accept_json(value, options)
          value.on("--id ID", "Schedule id") { |entry| id = entry }
          value.on("--interval SECONDS", Integer, "Fire every N seconds") { |entry| interval = entry }
          value.on("--at TIME", "Fire once at an ISO-8601 UTC instant") { |entry| at = entry }
          value.on("--task TASK", "The task to run each occurrence") { |entry| task = entry }
          value.on("--profile ID", "Trusted profile the occurrences run under") { |entry| profile_id = entry }
          value.on("--thread NAME", "Thread occurrences run on (default: schedule id)") do |entry|
            thread = entry
          end
          value.on("--max-steps N", Integer, "Per-occurrence step budget") { |entry| max_steps = entry }
          value.on("--max-wall-seconds N", Integer, "Per-occurrence wall-clock budget") do |entry|
            max_wall_seconds = entry
          end
        end.parse!(argv)

        validate_schedule_id!(id)
        raise OptionParser::MissingArgument, "--task" if task.to_s.empty?
        if interval.nil? && at.nil?
          raise OptionParser::MissingArgument, "--interval or --at"
        end
        if interval && at
          raise OptionParser::InvalidArgument, "--interval and --at are mutually exclusive"
        end

        with_worker_runtime(options) do |runtime|
          runtime.profile(profile_id) if profile_id
          thread_id = thread || "schedule.#{id}"
          runtime.bind_thread_profile(thread_id, profile_id)

          kind, expression, start_at = if interval
                                         [:interval, String(interval), Time.now.to_i]
                                       else
                                         instant, iso = parse_instant!(at)
                                         [:at, iso, instant]
                                       end

          payload_ref = runtime.store_schedule_payload(id, task)
          schedule = Tamoz::Scheduler::Schedule.new(
            id:, owner: "operator", kind:, expression:, start_at:,
            payload_ref:, thread_policy: thread_id,
            capability_grant: {"scopes" => ["read"]},
            behavior_version: "tamoz.agent.session/1",
            approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
            delivery_policy: {"mode" => "inbox"},
            # A schedule must carry a per-occurrence budget — unattended work with
            # no ceiling is how a runtime quietly burns a night. These are the
            # defaults an operator can override per schedule.
            budgets: schedule_budgets(max_steps, max_wall_seconds),
            created_by: "operator", created_at: Time.now.to_i
          )
          existing = runtime.schedule_store.fetch_schedule(id)
          stored = runtime.schedule_store.put_schedule(
            schedule, expected_revision: existing&.revision
          )

          emit_schedule(stored, options, verb: "Scheduled")
          0
        end
      end

      def schedule_list(options, argv)
        OptionParser.new do |value|
          value.banner = "Usage: tamoz schedule list"
          accept_json(value, options)
        end.parse!(argv)

        with_worker_runtime(options) do |runtime|
          schedules = runtime.schedule_store.list_schedules
          if options[:json]
            @out.puts JSON.generate("schedules" => schedules.map { |entry| schedule_document(entry, runtime) })
          elsif schedules.empty?
            @out.puts "No schedules."
          else
            @out.puts "%-20s %-9s %-10s %-8s %s" % %w[ID KIND EXPRESSION STATE TASK]
            schedules.each do |entry|
              @out.puts "%-20s %-9s %-10s %-8s %s" % [
                entry.id, entry.kind, entry.expression,
                entry.enabled ? "active" : "paused",
                runtime.schedule_payload(entry.id).to_s[0, 40]
              ]
            end
          end
          0
        end
      end

      def schedule_show(options, argv)
        id = argv.shift
        OptionParser.new { |value| accept_json(value, options) }.parse!(argv)
        validate_schedule_id!(id)

        with_worker_runtime(options) do |runtime|
          schedule = runtime.schedule_store.fetch_schedule(id)
          next schedule_missing(id) unless schedule

          document = schedule_document(schedule, runtime)
          if options[:json]
            @out.puts JSON.generate(document)
          else
            document.each { |key, value| @out.puts "#{key}: #{value}" }
          end
          0
        end
      end

      # Pause and resume are lifecycle, not definition: they flip `enabled` and
      # leave the schedule's digest alone, so resuming restores exactly the
      # schedule that was paused.
      def schedule_set_enabled(options, argv, enabled:)
        id = argv.shift
        OptionParser.new { |value| accept_json(value, options) }.parse!(argv)
        validate_schedule_id!(id)

        with_worker_runtime(options) do |runtime|
          schedule = runtime.schedule_store.fetch_schedule(id)
          next schedule_missing(id) unless schedule

          if enabled
            runtime.schedule_store.enable_schedule(id, expected_revision: schedule.revision)
          else
            runtime.schedule_store.disable_schedule(
              id, expected_revision: schedule.revision, reason: "paused by operator"
            )
          end

          if options[:json]
            @out.puts JSON.generate("id" => id, "enabled" => enabled)
          else
            @out.puts "#{enabled ? "Resumed" : "Paused"} #{id}"
          end
          0
        end
      end

      # Removal is a tombstone: the schedule stops firing and its occurrence
      # history survives. Deleting the evidence of what ran would be a strange
      # thing for a scheduler to offer.
      def schedule_remove(options, argv)
        id = argv.shift
        OptionParser.new { |value| accept_json(value, options) }.parse!(argv)
        validate_schedule_id!(id)

        with_worker_runtime(options) do |runtime|
          schedule = runtime.schedule_store.fetch_schedule(id)
          next schedule_missing(id) unless schedule

          runtime.schedule_store.disable_schedule(
            id, expected_revision: schedule.revision, reason: "removed by operator"
          )
          runtime.tombstone_schedule(id)

          if options[:json]
            @out.puts JSON.generate("id" => id, "removed" => true)
          else
            @out.puts "Removed #{id} (occurrence history retained)"
          end
          0
        end
      end

      # `run-now` queues the schedule's task immediately. It deliberately does NOT
      # fabricate an occurrence: an occurrence means "this schedule fired at this
      # nominal instant", and inventing one would corrupt the history that misfire
      # and catch-up decisions are made from. It is an ordinary queued task that
      # happens to borrow a schedule's text and authority.
      def schedule_run_now(options, argv)
        id = argv.shift
        OptionParser.new { |value| accept_json(value, options) }.parse!(argv)
        validate_schedule_id!(id)

        with_worker_runtime(options) do |runtime|
          schedule = runtime.schedule_store.fetch_schedule(id)
          next schedule_missing(id) unless schedule

          task = runtime.schedule_payload(id)
          unless task
            @err.puts "tamoz: schedule #{id} has no stored task payload"
            next 1
          end

          thread = schedule.thread_policy
          request_id = SecureRandom.uuid
          runtime.session_for(thread).app.durable_runner.submit(
            {"task" => task}, thread:, request_id:, operation: :turn, delivery: :queue
          )

          if options[:json]
            @out.puts JSON.generate("id" => id, "thread" => thread,
                                    "request_id" => request_id, "status" => "queued")
          else
            @out.puts "Queued #{request_id} from schedule #{id}"
          end
          0
        end
      end

      def schedule_occurrences(options, argv)
        id = argv.shift
        limit = 100
        OptionParser.new do |value|
          accept_json(value, options)
          value.on("--limit N", Integer, "Occurrences to show") { |entry| limit = entry }
        end.parse!(argv)
        validate_schedule_id!(id)

        with_worker_runtime(options) do |runtime|
          page = runtime.schedule_store.list_occurrences(schedule_id: id, limit:)
          rows = Array(page.respond_to?(:occurrences) ? page.occurrences : page)
          documents = rows.map { |entry| occurrence_document(entry) }
          if options[:json]
            @out.puts JSON.generate("schedule_id" => id, "occurrences" => documents)
          elsif documents.empty?
            @out.puts "No occurrences."
          else
            @out.puts "%-38s %-12s %s" % %w[OCCURRENCE STATE FIRED_AT]
            documents.each do |entry|
              @out.puts "%-38s %-12s %s" % [
                entry["occurrence_id"], entry["state"], entry["nominal_fire_at_utc"]
              ]
            end
          end
          0
        end
      end

      private

      DEFAULT_MAX_STEPS = 50
      DEFAULT_MAX_WALL_SECONDS = 900

      def schedule_budgets(max_steps, max_wall_seconds)
        {
          "max_steps" => max_steps || DEFAULT_MAX_STEPS,
          "max_wall_seconds" => max_wall_seconds || DEFAULT_MAX_WALL_SECONDS
        }
      end

      def validate_schedule_id!(id)
        raise OptionParser::MissingArgument, "--id" if id.to_s.empty?
        unless SCHEDULE_ID_PATTERN.match?(id)
          raise OptionParser::InvalidArgument,
                "schedule id #{id.inspect} must be letters, digits, underscore, dash or dot"
        end
      end

      # Returns [epoch, canonical ISO-8601 UTC text]. The schedule stores the
      # canonical spelling as its expression, so two operators writing the same
      # instant differently produce the same definition digest.
      def parse_instant!(text)
        parsed = Time.parse(String(text)).utc
        [parsed.to_i, parsed.strftime("%Y-%m-%dT%H:%M:%SZ")]
      rescue ArgumentError
        raise OptionParser::InvalidArgument, "--at must be an ISO-8601 instant, got #{text.inspect}"
      end

      def schedule_missing(id)
        @err.puts "tamoz: no schedule #{id.inspect}"
        1
      end

      def schedule_document(schedule, runtime)
        {
          "id" => schedule.id,
          "kind" => schedule.kind.to_s,
          "expression" => schedule.expression,
          "revision" => schedule.revision,
          "enabled" => schedule.enabled,
          "thread" => schedule.thread_policy,
          "definition_digest" => schedule.definition_digest,
          "task" => runtime.schedule_payload(schedule.id)
        }
      end

      def occurrence_document(occurrence)
        {
          "occurrence_id" => occurrence.occurrence_id,
          "state" => occurrence.state.to_s,
          "nominal_fire_at_utc" => occurrence.nominal_fire_at_utc,
          "request_id" => occurrence.request_id
        }
      end

      def emit_schedule(schedule, options, verb:)
        if options[:json]
          @out.puts JSON.generate(
            "id" => schedule.id, "revision" => schedule.revision,
            "kind" => schedule.kind.to_s, "expression" => schedule.expression,
            "enabled" => schedule.enabled
          )
        else
          @out.puts "#{verb} #{schedule.id} (#{schedule.kind} #{schedule.expression})"
        end
      end
    end
  end
end

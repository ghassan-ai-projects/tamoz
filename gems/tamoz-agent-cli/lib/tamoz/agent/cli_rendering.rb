# frozen_string_literal: true


module Tamoz
  module Agent
    # How a finished session reaches the operator: what is printed, and what the
    # shell gets back.
    #
    # Two audiences, one source of truth. `--json` emits a machine document and
    # the human form prints the same facts as text, so the two can never drift
    # into disagreeing about what happened — `show_document` builds the document
    # and `render_show_human` renders from the same view.
    #
    # The exit code is part of the rendering, not separate from it: a terminal
    # outcome is only fully reported when the shell can branch on it, which is
    # why exit_for_view and exit_for_cancellation live here beside the text they
    # accompany.
    #
    # Every method here was PRIVATE on the CLI before the extraction and stays
    # private, so including this module does not widen CLI's surface.
    #
    # CLI's own constants are referenced as `CLI::EXIT_PAUSED` and friends: a
    # module does not share the class's lexical scope, so the bare names that
    # resolved inside `class CLI` do not resolve here. This was caught by the
    # suite, not by rubocop or reek.
    #
    # Pinned by test/agent_cli_test.rb and test/agent_session_operations_test.rb.
    # rubocop:disable Metrics/ModuleLength -- one audience-facing surface: the
    # human and JSON renderings of a session plus the exit codes that accompany
    # them. Every method inside is within the Q6 ceilings.
    #
    # :reek:TooManyStatements — a renderer prints one line per field; a method
    # that emits N lines has N statements and there is no smaller unit.
    # :reek:FeatureEnvy — a renderer's whole job is to read the view it was given
    # and print it; the data is the subject, and moving these onto the view would
    # put @out and the operator's formatting choices inside the domain object.
    # :reek:UtilityFunction — `exit_for_view` and `show_document` are pure
    # mappings from a view to a value; they belong beside the text they
    # accompany, not on a collaborator of their own.
    # :reek:ControlParameter — `json:` is the operator's choice of AUDIENCE, and
    # `render_show` exists to route between the two renderings of the same view.
    # That routing is the method's entire job, not a hidden mode switch.
    # :reek:DataClump — (view, transcript) travel together because "how much of
    # the transcript to show" is an operator choice about THIS view; it is a
    # rendering option, not an undiscovered object.
    # :reek:LongParameterList — `render_show` takes the view plus the three
    # things the operator chose: which thread, how much transcript, and whether
    # they asked for JSON.
    module CLIRendering
      private

      def render_final_view(view, options:)
        if options[:json]
          emit_cli_event('cli.session', {
            'thread_id' => view.thread_id,
            'request_id' => view.request_id,
            'status' => view.status.to_s,
            'progress' => TerminalProgress.summarize(view),
            'terminal' => view.terminal,
            'status_projection' => SessionStatusProjection.document(view),
            'lifecycle_events' => SessionStatusProjection.lifecycle_events(view)
          })
        else
          render_final_view_human(view)
        end
      end

      def render_final_view_human(view)
        case view.status
        when :completed then render_verification(view)
        when :failed
          failure = if @stream_error
                      "tamoz: session failed: #{@stream_error}"
                    else
                      'tamoz: session failed before verified completion'
                    end
          @err.puts failure
          @err.puts "tamoz: #{TerminalProgress.progress_line(view)}"
          @err.puts "tamoz: Next action: #{TerminalProgress.next_action(view.terminal&.fetch('reason', nil))}"
        when :blocked
          @err.puts "tamoz: #{TerminalProgress.progress_line(view)}"
          @err.puts 'tamoz: session is blocked before verified completion'
          @err.puts "tamoz: Next action: #{TerminalProgress.next_action('effect_unknown')}"
        end
      end

      # A completed session prints its answer only when it verified one; a
      # completion without verification says nothing rather than something empty.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- one bounded terminal renderer.
      def render_verification(view)
        verification = view.state&.fetch(:verification, nil)
        return unless verification

        answer = verification.fetch('answer', '')
        @out.puts answer unless answer.empty?
        reason = view.terminal&.fetch('reason', nil)
        if reason == 'direct_response'
          @out.puts 'Response provided; no task completion was claimed.'
        elsif verification.fetch('satisfied', false)
          artifact_line = TerminalProgress.artifact_line(view)
          @out.puts artifact_line if artifact_line
          @out.puts "\nVerification: satisfied"
        else
          @out.puts TerminalProgress.progress_line(view)
          artifact_line = TerminalProgress.artifact_line(view)
          @out.puts artifact_line if artifact_line
          @out.puts 'Verification: not satisfied'
          @out.puts "Next action: #{TerminalProgress.next_action(reason)}"
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def exit_for_view(view)
        case view.status
        when :completed then view.terminal&.fetch('satisfied', false) ? 0 : 2
        when :paused, :blocked then CLI::EXIT_PAUSED
        else 1 # :failed, and any status this CLI does not model
        end
      end

      def exit_for_cancellation
        case @cancellation&.reason
        when 'sigint' then CLI::EXIT_SIGINT
        when 'sigterm' then CLI::EXIT_SIGTERM
        else 1
        end
      end

      def render_show(view, thread_id:, transcript:, json:)
        if json
          @out.puts JSON.generate(show_document(view, thread_id:, transcript:))
        else
          render_show_human(view, thread_id:, transcript:)
        end
      end

      def show_document(view, thread_id:, transcript:)
        receipts = view.effect_receipts.last(transcript).map(&:to_h)
        {
          'thread_id' => thread_id,
          'checkpoint_id' => view.checkpoint_id,
          'sequence' => view.sequence,
          'status' => view.status.to_s,
          'accepted_plan_digest' => view.accepted_plan&.fetch('plan_digest', nil),
          'interrupts' => view.interrupts.map do |interrupt|
            { 'task_id' => interrupt.task_id, 'call_index' => interrupt.call_index,
              'descriptor' => interrupt.descriptor }
          end,
          'effect_receipts' => receipts,
          'progress' => TerminalProgress.summarize(view),
          'terminal' => view.terminal,
          'status_projection' => SessionStatusProjection.document(view),
          'lifecycle_events' => SessionStatusProjection.lifecycle_events(view)
        }
      end

      def render_show_human(view, thread_id:, transcript:)
        render_show_header(view, thread_id)
        render_show_interrupts(view)
        render_show_receipts(view, transcript)
        render_show_terminal(view)
      end

      def render_show_header(view, thread_id)
        @out.puts "Thread: #{thread_id}"
        @out.puts "Checkpoint: #{view.checkpoint_id} (sequence #{view.sequence})"
        @out.puts "Status: #{view.status}"
        projection = SessionStatusProjection.document(view)
        @out.puts "Task: #{projection.fetch('task_state')} (phase #{projection.fetch('phase')})"
        @out.puts "Effect: #{projection.fetch('effect_state')}"
        @out.puts "Capability: #{projection.fetch('capability_state')}"
        @out.puts "Delivery: #{projection.fetch('delivery_state')}"
        plan = view.accepted_plan
        @out.puts "Accepted plan digest: #{plan.fetch('plan_digest', 'unknown')}" if plan
      end

      # Each of these prints nothing at all when it has nothing to say, so an
      # empty session reads as empty rather than as a list of empty headings.
      def render_show_interrupts(view)
        interrupts = view.interrupts
        return if interrupts.empty?

        @out.puts 'Pending interrupts:'
        interrupts.each do |interrupt|
          @out.puts "  - #{interrupt.descriptor['kind']} #{interrupt.task_id}/#{interrupt.call_index}"
        end
      end

      def render_show_receipts(view, transcript)
        receipts = view.effect_receipts.last(transcript)
        return if receipts.empty?

        @out.puts 'Recent effect receipts:'
        receipts.each { |receipt| @out.puts "  - #{receipt.fetch('operation', 'unknown')}" }
      end

      def render_show_terminal(view)
        terminal = view.terminal
        return unless terminal

        @out.puts "Terminal: #{terminal.fetch('reason', 'unknown')} " \
                  "(satisfied: #{terminal.fetch('satisfied', false)})"
      end

      def list_entry(path, options)
        thread_id = File.basename(path, '.sqlite3')
        return nil unless CLI::THREAD_ID_PATTERN.match?(thread_id)

        adapter = Tamoz::SQLite::Adapter.new(path:)
        begin
          read_list_entry(adapter, options, path, thread_id)
        ensure
          adapter.close
        end
      # Skip a file that is not a readable Tamoz thread. This rescue used to
      # catch StandardError, which hid a NoMethodError (`updated_at_ms` is not
      # a Checkpoint member) and made every `list` report nothing at all.
      rescue Tamoz::Error, SQLite3::Exception
        nil
      end

      # nil means "this file is not a listable thread" — no checkpoint yet — and
      # the caller filters it out rather than showing an empty row.
      def read_list_entry(adapter, options, path, thread_id)
        session = build_list_session(adapter, options)
        return nil unless session.app.checkpointer.latest(thread_id:, namespace: [])

        view = session.view(thread: thread_id)
        state = view.state
        {
          'thread_id' => thread_id,
          'status' => view.status.to_s,
          # No checkpoint value carries a wall-clock stamp, so the session file's
          # last write is the honest last-activity signal here.
          'updated_at_ms' => (File.mtime(path).to_f * 1000).round,
          'summary' => state ? state[:task].to_s[0, 40] : ''
        }
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    # The served surfaces' loops: one gateway thread per surface, its drainer thread started once the gateway
    # holds the lease, all stopped together. A failure in any is named on stderr and exits non-zero, never a quiet
    # spin beside a dead sibling.
    # :reek:FeatureEnvy, :reek:LongParameterList
    module CLICommsLoops
      STOPPING_OUTCOMES = %i[auth_failed poller_conflict poller_busy].freeze
      FAILED_OUTCOMES = %i[auth_failed authentication_refused poller_busy].freeze
      REFUSED = 'stopped on Comms::AuthenticationError: the channel credential was refused'
      REFUSED_CREDENTIAL = { auth_failed: "comms gateway #{REFUSED}",
                             authentication_refused: "comms delivery #{REFUSED}" }
                           .freeze

      private

      # Trap.install hands each stop request to a thread: `stop` releases the poller lease with a database write,
      # whose mutex raises ThreadError in a trap context.
      def run_gateway_loops(store, surfaces)
        stop = ->(_reason) { stop_loops(surfaces) }
        Cancellation::Trap.install(int: stop, term: stop) do
          failures = Queue.new
          drainers = Queue.new
          outcomes = surfaces.map { |surface| gateway_thread(store, surface, surfaces, failures, drainers) }
                             .map(&:value)
          busy = busy_surfaces(surfaces, outcomes)
          outcomes += drained(drainers).map(&:value)
          report_loop_failures(drained(failures), outcomes, busy)
        ensure
          stop_loops(surfaces)
        end
      end

      def drained(queue) = Array.new(queue.size) { queue.pop }

      def busy_surfaces(surfaces, outcomes)
        surfaces.zip(outcomes).filter_map do |surface, outcome|
          surface.descriptor.surface_id if outcome == :poller_busy
        end
      end

      def gateway_thread(store, surface, surfaces, failures, drainers)
        Thread.new do
          started = lambda do
            start_connection(store, surface)
            drainers << drainer_thread(surface, surfaces, failures)
          end
          outcome = surface.gateway.serve_loop(drain: false, interval_s: surface.connection.interval_s,
                                               on_started: started)
          stop_loops(surfaces) if STOPPING_OUTCOMES.include?(outcome)
          outcome
        rescue StandardError => e
          supervised_failure(e, failures, surfaces)
        end
      end

      def drainer_thread(surface, surfaces, failures)
        Thread.new do
          outcome = surface.drainer.serve_loop
          stop_loops(surfaces) if outcome == :authentication_refused
          outcome
        rescue StandardError => e
          supervised_failure(e, failures, surfaces)
        end
      end

      def supervised_failure(error, failures, surfaces)
        failures << error
        stop_loops(surfaces)
        :storage_failed
      end

      def report_loop_failures(failures, outcomes, busy)
        failures.each { |failure| @err.puts "tamoz: #{failure_line(failure)}" }
        REFUSED_CREDENTIAL.each { |outcome, message| @err.puts "tamoz: #{message}" if outcomes.include?(outcome) }
        @err.puts "tamoz: another run holds #{busy.join(', ')}; stop it first" if busy.any?
        return 1 if failures.any? || outcomes.intersect?(FAILED_OUTCOMES)
        raise Comms::PollerConflictError, 'a gateway lost the poller lease' if outcomes.include?(:poller_conflict)

        0
      end

      def failure_line(failure)
        named = failure.is_a?(Comms::ConnectionError) ? '' : "comms delivery stopped on #{failure.class}: "
        "#{named}#{failure.message}"
      end

      def stop_loops(surfaces)
        surfaces.each do |surface|
          surface.gateway&.stop
          surface.drainer&.stop
          surface.connection.stop
        end
      end

      def start_connection(store, surface)
        descriptor = surface.descriptor
        surface.connection.start(
          floor: store.poll_offset(stream_id: descriptor.identity.fetch(:stream_id)),
          history: store.delivered_messages(surface_id: descriptor.surface_id, limit: 50)
        )
      end
    end
  end
end

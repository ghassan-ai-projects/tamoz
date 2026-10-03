# frozen_string_literal: true

module Tamoz
  module Circuit
    # One owner's failure evidence inside a circuit record: how each condition kind accumulates and when it is met.
    module OwnerTally
      module_function

      def blank_entry
        { 'failures' => 0, 'conditions' => {} }
      end

      def record_failure(entry, conditions, event, now_ms:)
        conditions.each { |condition| count_failure(entry, condition, event, now_ms) }
      end

      def record_success(entry, every_outcome_conditions, now_ms:)
        entry['failures'] = 0
        every_outcome_conditions.each do |condition|
          append_event(entry, condition, { 'outcome' => 'success', 'observed_at_ms' => now_ms }, now_ms)
        end
      end

      def window_observation(event, now_ms)
        { 'digest' => event.context_digest, 'observed_at_ms' => now_ms }
      end

      def count_failure(entry, condition, event, now_ms)
        case condition.kind
        when 'consecutive' then entry['failures'] = entry.fetch('failures', 0) + 1
        when 'immediate' then count_immediate(entry, condition, now_ms)
        when 'window' then append_event(entry, condition, window_observation(event, now_ms), now_ms)
        when 'run' then count_run(entry, condition, event.run_id, event.fingerprint)
        when 'rate' then append_event(entry, condition, { 'outcome' => 'failure', 'observed_at_ms' => now_ms }, now_ms)
        end
      end

      def met?(condition, entry, now_ms)
        case condition.kind
        when 'consecutive' then entry.fetch('failures', 0) >= condition.threshold
        when 'immediate' then sub_value(entry, condition, 'count', 0) >= condition.threshold
        when 'window' then recent_events(entry, condition, now_ms).length >= condition.threshold
        when 'run' then sub_value(entry, condition, 'counts', {}).each_value.any? { _1 >= condition.threshold }
        when 'rate' then rate_exceeded?(entry, condition, now_ms)
        else false
        end
      end

      def rate_exceeded?(entry, condition, now_ms)
        events = recent_events(entry, condition, now_ms)
        return false if events.length < condition.min_samples

        failures = events.count { |event| event['outcome'] == 'failure' }
        (failures.to_f / events.length) >= condition.max_rate
      end

      def recent_events(entry, condition, now_ms)
        prune(sub_value(entry, condition, 'events', []), condition.window_ms, now_ms)
      end

      def sub_value(entry, condition, key, default)
        entry.dig('conditions', condition.id, key) || default
      end

      def count_immediate(entry, condition, now_ms)
        sub = entry['conditions'][condition.id] ||= { 'kind' => 'immediate', 'count' => 0 }
        sub['count'] += 1
        sub['last_at_ms'] = now_ms
      end

      def append_event(entry, condition, event, now_ms)
        sub = entry['conditions'][condition.id] ||=
          { 'kind' => condition.kind, 'window_ms' => condition.window_ms, 'events' => [] }
        sub['events'] = (prune(sub.fetch('events'), condition.window_ms, now_ms) + [event]).last(MAX_WINDOW_EVENTS)
      end

      def count_run(entry, condition, run_id, fingerprint)
        require_run_identity!(condition, run_id, fingerprint)
        sub = entry['conditions'][condition.id] ||= { 'kind' => 'run', 'run_id' => nil, 'counts' => {} }
        run = Circuit.identity!(run_id, name: 'circuit run id')
        sub['counts'] = {} unless sub['run_id'] == run
        sub['run_id'] = run
        normalized_fingerprint = Circuit.identity!(fingerprint, name: 'failure fingerprint')
        sub['counts'] = count_keeping_highest(sub.fetch('counts'), normalized_fingerprint)
      end

      def require_run_identity!(condition, run_id, fingerprint)
        return unless run_id.nil? || fingerprint.nil?

        raise ConfigurationError, "condition #{condition.id} requires run_id: and fingerprint:"
      end

      def prune(events, window_ms, now_ms)
        return events if window_ms.nil? || now_ms.nil?

        events.select do |event|
          observed = event['observed_at_ms']
          observed.is_a?(Integer) && observed <= now_ms && (now_ms - observed) < window_ms
        end
      end

      def count_keeping_highest(counts, fingerprint)
        next_counts = counts.merge(fingerprint => (counts[fingerprint] || 0) + 1)
        return next_counts if next_counts.length <= MAX_RUN_FINGERPRINTS

        kept = next_counts.sort_by { |key, value| [-value, key] }.first(MAX_RUN_FINGERPRINTS).to_h
        kept[fingerprint] = next_counts.fetch(fingerprint)
        kept
      end
    end
  end
end

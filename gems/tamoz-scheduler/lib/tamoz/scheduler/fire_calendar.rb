# frozen_string_literal: true

module Tamoz
  module Scheduler
    # When a schedule fires: its next nominal instant and the instants already due.
    class FireCalendar
      def initialize(schedule)
        @schedule = schedule
      end

      def next_fire_at(now)
        return nil unless available_at?(now)

        case kind
        when :at then next_at_fire(now)
        when :interval then next_interval_fire(now)
        end
      end

      def due_occurrences(now:, anchor:, limit:)
        return [] unless available_at?(now)

        case kind
        when :at then due_at_occurrences(now)
        when :interval then due_interval_occurrences(now:, anchor: anchor || interval_anchor, limit:)
        end
      end

      private

      def kind = @schedule.kind
      def expression = @schedule.expression
      def start_at = @schedule.start_at
      def end_at = @schedule.end_at

      def available_at?(now)
        @schedule.enabled && (!end_at || now <= end_at)
      end

      def next_at_fire(now)
        instant = Schedule.at_instant(expression)
        return nil if instant <= now
        return nil unless within_bounds?(instant)

        instant
      end

      def next_interval_fire(now)
        duration = expression.to_i
        anchor = interval_anchor
        return nil if end_at && anchor > end_at
        return anchor if now < anchor

        anchor + ((((now - anchor) / duration).floor + 1) * duration)
      end

      def due_at_occurrences(now)
        instant = Schedule.at_instant(expression)
        return [] if instant > now
        return [] unless within_bounds?(instant)

        [instant]
      end

      def interval_anchor
        start_at || @schedule.created_at
      end

      def due_interval_occurrences(now:, anchor:, limit:)
        duration = expression.to_i
        return [] if end_at && anchor > end_at
        return [] if anchor > now

        (0...[((now - anchor) / duration) + 1, limit].min)
          .map { |ordinal| anchor + (ordinal * duration) }
      end

      def within_bounds?(instant)
        (!start_at || instant >= start_at) && (!end_at || instant <= end_at)
      end
    end

    private_constant :FireCalendar
  end
end

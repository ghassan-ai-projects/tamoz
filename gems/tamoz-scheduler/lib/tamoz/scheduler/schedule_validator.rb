# frozen_string_literal: true

module Tamoz
  module Scheduler
    # The rules a schedule definition must satisfy before it becomes a Schedule value.
    class ScheduleValidator
      def initialize(fields)
        @fields = fields
      end

      def validate!
        # An omitted profile is the default one, not an error, so a schedule
        # that says nothing runs under the same policy as ordinary work.
        @fields[:approval_profile] = DEFAULT_APPROVAL_PROFILE if @fields[:approval_profile].nil?

        validate_identity!(@fields)
        validate_kind!(@fields)
        validate_times!(@fields)
        validate_expression!(@fields[:kind], @fields[:expression])
        validate_policies!(@fields)
        validate_artifacts!(@fields)
        validate_lifecycle!(@fields)

        @fields.freeze
      end

      private

      def validate_identity!(fields)
        validate_id!(fields[:id])
        validate_revision!(fields[:revision])
        validate_string!(fields[:owner], 'owner')
      end

      def validate_policies!(fields)
        validate_enum!(fields[:misfire_policy], MISFIRE_POLICIES, 'misfire_policy')
        validate_limit!(fields[:misfire_limit], 'misfire_limit')
        validate_enum!(fields[:overlap_policy], OVERLAP_POLICIES, 'overlap_policy')
        validate_limit!(fields[:max_concurrency], 'max_concurrency')
        validate_limit!(fields[:jitter_window], 'jitter_window')
      end

      def validate_artifacts!(fields)
        validate_digest!(fields[:payload_ref], 'payload_ref')
        validate_string!(fields[:thread_policy], 'thread_policy')
        validate_hash!(fields[:capability_grant], 'capability_grant')
        validate_string!(fields[:behavior_version], 'behavior_version')
        validate_string!(fields[:approval_profile], 'approval_profile')
        validate_hash!(fields[:delivery_policy], 'delivery_policy')
        validate_budgets!(fields[:budgets])
      end

      def validate_lifecycle!(fields)
        validate_string!(fields[:created_by], 'created_by')
        validate_time!(fields[:created_at], 'created_at')
      end

      def validate_id!(value)
        unless value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_.-]{0,255}\z/)
          raise Tamoz::ConfigurationError,
                'schedule id must be a bounded lowercase identifier'
        end
        value.freeze
      end

      def validate_revision!(value)
        unless value.is_a?(Integer) && value >= 1
          raise Tamoz::ConfigurationError, 'schedule revision must be a positive integer'
        end

        value
      end

      def validate_kind!(fields)
        unless KINDS.include?(fields[:kind])
          raise Tamoz::ConfigurationError,
                "schedule kind must be one of #{KINDS.inspect} (cron is a recorded deferral)"
        end
        expression = fields[:expression]
        return if expression.is_a?(String) && !expression.empty?

        raise Tamoz::ConfigurationError, 'schedule expression must be a non-empty string'
      end

      def validate_times!(fields)
        start_at = fields[:start_at]
        end_at = fields[:end_at]
        validate_time!(start_at, 'start_at') unless start_at.nil?
        validate_time!(end_at, 'end_at') unless end_at.nil?
        return unless start_at && end_at && start_at > end_at

        raise Tamoz::ConfigurationError, 'start_at must not exceed end_at'
      end

      def validate_expression!(kind, expression)
        case kind
        when :at
          unless expression.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
            raise Tamoz::ConfigurationError,
                  'at expression must be an ISO-8601 UTC instant (YYYY-MM-DDTHH:MM:SSZ)'
          end

          # The shape is not the instant: `2024-13-99T25:61:61Z` matches the
          # pattern and is not a time. Resolving it here means the operator
          # learns at `schedule add`, not the poller at fire time.
          Schedule.at_instant(expression)
        when :interval
          unless expression.match?(/\A\d+\z/) && expression.to_i.positive?
            raise Tamoz::ConfigurationError,
                  'interval expression must be a positive integer duration in seconds'
          end
        end
      end

      def validate_enum!(value, set, name)
        raise Tamoz::ConfigurationError, "#{name} must be one of #{set.inspect}" unless set.include?(value)

        value
      end

      def validate_limit!(value, name)
        unless value.is_a?(Integer) && value >= 0 && value <= MAX_BUDGET_MAGNITUDE
          raise Tamoz::ConfigurationError, "#{name} must be a bounded non-negative integer"
        end

        value
      end

      def validate_digest!(value, name)
        raise Tamoz::ConfigurationError, "#{name} must be a sha256:... digest" unless Tamoz::Core.valid_digest?(value)

        value.freeze
      end

      def validate_string!(value, name)
        unless value.is_a?(String) && !value.strip.empty? && value.bytesize <= 4096
          raise Tamoz::ConfigurationError, "#{name} must be a bounded non-empty string"
        end

        value.freeze
      end

      def validate_hash!(value, name)
        raise Tamoz::ConfigurationError, "#{name} must be a non-empty hash" unless value.is_a?(Hash) && !value.empty?

        Tamoz::Core.deep_freeze(value)
      end

      def validate_budgets!(value)
        validate_hash!(value, 'budgets')
        %w[max_steps max_wall_seconds max_cost_tokens].each do |key|
          next unless value.key?(key)
          next if value[key].is_a?(Integer) && value[key].positive?

          raise Tamoz::ConfigurationError,
                "budgets.#{key} must be a positive integer"
        end
      end

      def validate_time!(value, name)
        unless value.is_a?(Integer) && value.positive?
          raise Tamoz::ConfigurationError, "#{name} must be a positive UTC epoch second"
        end

        value
      end
    end

    private_constant :ScheduleValidator
  end
end

# frozen_string_literal: true

module Tamoz
  module Tools
    # Freezes the operator-supplied tool and check policy at toolbox construction.
    # :reek:FeatureEnvy :reek:TooManyStatements -- each normalized policy surface
    # has a distinct validation contract and must be captured before execution.
    # :reek:LongParameterList -- construction receives the complete immutable
    # policy boundary so normalization cannot silently consult global state.
    # :reek:ControlParameter :reek:DuplicateMethodCall :reek:NilCheck -- the
    # optional policy fields and run-check admission are explicit boundary rules.
    # :reek:MissingSafeMethod -- malformed policy must raise during construction.
    class ToolPolicyNormalizer
      CHECK_SAFETIES = %i[read_only idempotent unsafe].freeze
      DEFAULT_CHECK_SAFETY = :unsafe

      attr_reader :checks, :check_safeties, :allowed_tools, :approval_required

      def initialize(policy:)
        @checks = normalize_checks(policy.fetch(:checks))
        @check_safeties = normalize_check_safeties(policy.fetch(:check_safeties))
        @allowed_tools = normalize_allowed_tools(
          policy.fetch(:allowed_tools),
          available_tools(policy.fetch(:base_available_tools), policy.fetch(:allow_changes))
        )
        @approval_required = normalize_approval_required(
          policy.fetch(:approval_required),
          @allowed_tools,
          policy.fetch(:default_approval_required)
        )
        freeze
      end

      private

      def available_tools(base, allow_changes)
        return base.freeze unless allow_changes && !@checks.empty?

        base + ['run_check']
      end

      def normalize_checks(value)
        raise ArgumentError, 'checks must be a Hash' unless value.is_a?(Hash)

        value.to_h { |raw_name, raw_argv| normalize_check(raw_name, raw_argv) }.freeze
      end

      def normalize_check(raw_name, raw_argv)
        name = normalize_check_name(raw_name)
        raw_argv = normalize_check_argv(name, raw_argv)

        validate_check_program!(name, raw_argv.first)
        [name.freeze, raw_argv.map { |entry| entry.dup.freeze }.freeze]
      end

      def normalize_check_name(raw_name)
        name = String(raw_name)
        return name if name.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)

        raise ArgumentError, "invalid check name #{name.inspect}"
      end

      def normalize_check_argv(name, value)
        return value if value.is_a?(Array) && !value.empty? &&
                        value.all? { |entry| entry.is_a?(String) && !entry.empty? && !entry.include?("\0") }

        raise ArgumentError, "check #{name.inspect} must be a non-empty argv Array"
      end

      def validate_check_program!(name, program)
        return unless program.include?(File::SEPARATOR) ||
                      (File::ALT_SEPARATOR && program.include?(File::ALT_SEPARATOR))
        return if program.start_with?(File::SEPARATOR)

        raise ArgumentError,
              "check #{name.inspect} argv[0] #{program.inspect} is a relative path and would " \
              'resolve inside the workspace; use an absolute path or a bare program name'
      end

      def normalize_check_safeties(value)
        raise ArgumentError, 'check_safeties must be a Hash' unless value.is_a?(Hash)

        value.to_h do |raw_name, raw_safety|
          name = String(raw_name)
          raise ArgumentError, "check_safeties names unconfigured check #{name.inspect}" unless @checks.key?(name)

          safety = raw_safety.to_sym
          unless CHECK_SAFETIES.include?(safety)
            raise ArgumentError,
                  "check #{name.inspect} safety must be one of #{CHECK_SAFETIES.join(', ')}"
          end

          [name.freeze, safety]
        end.freeze
      end

      def normalize_allowed_tools(value, available)
        return available.freeze if value.nil?

        validate_allowed_tools!(value, available)

        value.map { |name| name.dup.freeze }.freeze
      end

      def validate_allowed_tools!(value, available)
        unless value.is_a?(Array) && !value.empty? &&
               value.all?(String) && value.uniq == value
          raise ArgumentError, 'allowed_tools must be a non-empty Array of distinct tool names'
        end

        unknown = value - available
        return if unknown.empty?

        raise ArgumentError,
              "allowed_tools names unavailable tools: #{unknown.sort.join(', ')} " \
              "(available: #{available.sort.join(', ')})"
      end

      def normalize_approval_required(value, allowed, default)
        return default if value.nil?
        unless value.is_a?(Array) &&
               value.all?(String) && value.uniq == value
          raise ArgumentError, 'approval_required must be an Array of distinct tool names'
        end

        unknown = value - allowed
        unless unknown.empty?
          raise ArgumentError,
                "approval_required must be a subset of allowed_tools: #{unknown.sort.join(', ')}"
        end

        value.map { |name| name.dup.freeze }.freeze
      end
    end
  end
end

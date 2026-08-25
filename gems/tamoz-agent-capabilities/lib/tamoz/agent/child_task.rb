# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    # Durable child-task identity and authority narrowing. Execution remains
    # owned by the request inbox/worker; this value object prevents a model
    # result from becoming an in-memory authority registry.
    class ChildTask
      STATUSES = %w[pending running completed failed unknown].freeze
      MAX_TASK_BYTES = 4 * 1024
      MAX_CAPABILITIES = 32
      DELEGATION_POLICY_KEYS = %w[remaining_depth remaining_concurrency].freeze
      DEFAULT_DELEGATION_POLICY = {
        'remaining_depth' => 0,
        'remaining_concurrency' => 0
      }.freeze
      ALLOWED_TRANSITIONS = {
        'pending' => %w[running failed unknown],
        'running' => %w[completed failed unknown],
        'completed' => [],
        'failed' => [],
        'unknown' => []
      }.freeze

      attr_reader :child_id, :parent_thread_id, :parent_request_id, :task,
                  :capability_profile, :depth, :concurrency, :status,
                  :completion_digest

      def self.build(**attributes)
        parent_thread_id = attributes.fetch(:parent_thread_id)
        parent_request_id = attributes.fetch(:parent_request_id)
        task = attributes.fetch(:task)
        capability_profile = attributes.fetch(:capability_profile)
        depth = attributes.fetch(:depth)
        concurrency = attributes.fetch(:concurrency)
        new(
          child_id: child_id(parent_thread_id, parent_request_id, task, capability_profile),
          parent_thread_id:, parent_request_id:, task:, capability_profile:,
          depth:, concurrency:, status: 'pending', completion_digest: nil
        )
      end

      def self.from_h(value)
        new(**value.transform_keys(&:to_sym))
      end

      def self.child_id(parent_thread_id, parent_request_id, task, capability_profile)
        payload = Tamoz::Core.canonical(
          'parent_thread_id' => String(parent_thread_id),
          'parent_request_id' => String(parent_request_id),
          'task' => String(task),
          'capability_profile' => identity_profile(capability_profile)
        )
        "child:sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
      end

      def self.identity_profile(profile)
        profile.reject { |key, _value| String(key) == 'delegation_policy' }
      end

      def initialize(**attributes)
        expected_keys = %i[child_id parent_thread_id parent_request_id task capability_profile depth
                           concurrency status completion_digest]
        validate_attribute_keys!(attributes, expected_keys)
        assign_identity(attributes)
        assign_policy(attributes)
        assign_state(attributes)
        expected_id = self.class.child_id(@parent_thread_id, @parent_request_id, @task, @capability_profile)
        raise ArgumentError, 'child task identity does not match its canonical inputs' unless @child_id == expected_id

        freeze
      end

      def assign_identity(attributes)
        @child_id = require_text(attributes.fetch(:child_id), 'child_id')
        @parent_thread_id = require_text(attributes.fetch(:parent_thread_id), 'parent_thread_id')
        @parent_request_id = require_text(attributes.fetch(:parent_request_id), 'parent_request_id')
        @task = validate_task!(attributes.fetch(:task))
      end

      def assign_policy(attributes)
        @capability_profile = validate_profile(attributes.fetch(:capability_profile))
        @depth = validate_integer(attributes.fetch(:depth), 'depth', 0..8)
        @concurrency = validate_integer(attributes.fetch(:concurrency), 'concurrency', 1..16)
      end

      def assign_state(attributes)
        @status = String(attributes.fetch(:status))
        raise ArgumentError, "unknown child task status #{@status.inspect}" unless STATUSES.include?(@status)

        completion_digest = attributes.fetch(:completion_digest)
        @completion_digest = completion_digest && require_text(completion_digest, 'completion_digest')
      end

      def to_h
        {
          'child_id' => child_id,
          'parent_thread_id' => parent_thread_id,
          'parent_request_id' => parent_request_id,
          'task' => task,
          'capability_profile' => capability_profile,
          'depth' => depth,
          'concurrency' => concurrency,
          'status' => status,
          'completion_digest' => completion_digest
        }
      end

      def delegation_policy = capability_profile.fetch('delegation_policy')

      def delegation_enabled?
        delegation_policy.values_at('remaining_depth', 'remaining_concurrency').all?(&:positive?)
      end

      def start
        transition('running')
      end

      def complete(receipt:) = transition_with_receipt('completed', receipt)
      def fail(receipt:) = transition_with_receipt('failed', receipt)
      def unknown(receipt:) = transition_with_receipt('unknown', receipt)

      def adoptable?
        %w[completed failed unknown].include?(status)
      end

      def assert_narrowed_to!(parent_profile)
        validate_parent_identity!(parent_profile)
        enforce_parent_bounds!(parent_profile)
        self
      end

      private

      def validate_attribute_keys!(attributes, expected_keys)
        unknown_keys = attributes.keys - expected_keys
        return if unknown_keys.empty?

        raise ArgumentError, "unknown child task attributes: #{unknown_keys.join(', ')}"
      end

      def validate_parent_profile!(parent_profile)
        return if parent_profile.is_a?(Hash) && parent_profile.keys.all?(String)

        raise ArgumentError, 'parent capability profile must be a string-keyed object'
      end

      def validate_parent_capabilities!(parent_profile)
        parent_capabilities = Array(parent_profile.fetch('capabilities', []))
        child_capabilities = Array(capability_profile.fetch('capabilities', []))
        return if (child_capabilities - parent_capabilities).empty?

        raise Tamoz::Agent::ToolPolicyError, 'child capabilities exceed parent authority'
      end

      def validate_parent_revision!(parent_profile)
        parent_revision = parent_profile.fetch('authority_revision', nil)
        child_revision = capability_profile.fetch('authority_revision', nil)
        return if parent_revision && child_revision == parent_revision

        raise Tamoz::Agent::ToolPolicyError, 'child authority revision is missing or differs from parent'
      end

      def transition(next_status, completion_digest: self.completion_digest)
        unless ALLOWED_TRANSITIONS.fetch(status).include?(next_status)
          raise ArgumentError, "child task cannot transition #{status} -> #{next_status}"
        end

        self.class.new(
          child_id:, parent_thread_id:, parent_request_id:, task:,
          capability_profile:, depth:, concurrency:, status: next_status,
          completion_digest:
        )
      end

      def validate_profile(profile)
        validate_profile_shape(profile)
        raise Tamoz::SensitiveValueError, 'child capability profile cannot contain credential-shaped values' if
          Tamoz::Core.secret_shaped?(profile)

        validate_capabilities(profile.fetch('capabilities', []))
        normalized = Tamoz::Core.canonical(profile)
        normalized['delegation_policy'] = validate_delegation_policy(
          normalized.fetch('delegation_policy', DEFAULT_DELEGATION_POLICY)
        )

        Tamoz::Core.deep_freeze(normalized)
      end

      def validate_profile_shape(profile)
        return if profile.is_a?(Hash) && profile.keys.all?(String)

        raise ArgumentError, 'child capability_profile must be a string-keyed object'
      end

      def validate_capabilities(capabilities)
        valid = capabilities.is_a?(Array) && capabilities.length <= MAX_CAPABILITIES &&
                capabilities.all? { |name| name.is_a?(String) && !name.empty? }
        return if valid

        raise ArgumentError, 'child capability_profile capabilities are invalid'
      end

      def validate_delegation_policy(policy)
        unless policy.is_a?(Hash) && policy.keys.all? { |key| DELEGATION_POLICY_KEYS.include?(String(key)) }
          raise ArgumentError, 'child delegation policy is invalid'
        end

        normalized = DELEGATION_POLICY_KEYS.to_h do |key|
          [key, validate_integer(policy.fetch(key), key, delegation_range_for(key))]
        end
        normalized.freeze
      end

      def validate_integer(value, name, range)
        unless value.is_a?(Integer) && range.cover?(value)
          raise ArgumentError, "child #{name} must be an integer in #{range}"
        end

        value
      end

      def require_text(value, name)
        text = String(value)
        raise ArgumentError, "child #{name} must not be empty" if text.empty?

        text.freeze
      end

      def enforce_parent_limit!(parent_profile, key, value)
        limit = parent_profile.fetch(key, nil)
        return if limit.nil?
        return if limit.is_a?(Integer) && value <= limit

        raise Tamoz::Agent::ToolPolicyError, "child #{key.delete_prefix('max_child_')} exceeds parent limit"
      end

      def enforce_policy_limit!(parent_profile, limit_key, child_value, remaining_key)
        limit = parent_profile.fetch(limit_key, nil)
        return unless limit

        maximum_remaining = [limit - child_value, 0].max
        return if delegation_policy.fetch(remaining_key) <= maximum_remaining

        message = "child #{remaining_key.delete_prefix('remaining_')} exceeds parent allowance"
        raise Tamoz::Agent::ToolPolicyError, message
      end

      def transition_with_receipt(next_status, receipt)
        receipt_text = require_text(receipt, 'receipt')
        transition(next_status, completion_digest: "sha256:#{Digest::SHA256.hexdigest(receipt_text)}")
      end

      def validate_task!(task)
        text = require_text(task, 'task')
        raise ArgumentError, "child task exceeds #{MAX_TASK_BYTES} bytes" if text.bytesize > MAX_TASK_BYTES
        if Tamoz::Core.secret_shaped?(task)
          raise Tamoz::SensitiveValueError, 'child task cannot contain credential-shaped values'
        end

        text
      end

      def validate_parent_identity!(parent_profile)
        validate_parent_profile!(parent_profile)
        validate_parent_capabilities!(parent_profile)
        validate_parent_revision!(parent_profile)
      end

      def enforce_parent_bounds!(parent_profile)
        enforce_parent_limit!(parent_profile, 'max_child_depth', depth)
        enforce_parent_limit!(parent_profile, 'max_child_concurrency', concurrency)
        enforce_policy_limit!(parent_profile, 'max_child_depth', depth, 'remaining_depth')
        enforce_policy_limit!(parent_profile, 'max_child_concurrency', concurrency, 'remaining_concurrency')
      end

      def delegation_range_for(key)
        key == 'remaining_concurrency' ? 0..16 : 0..8
      end
    end
  end
end

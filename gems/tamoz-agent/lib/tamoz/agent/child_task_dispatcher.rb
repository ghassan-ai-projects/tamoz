# frozen_string_literal: true

require 'json'
require_relative 'child_task'

module Tamoz
  module Agent
    # The session-facing delegation capability. It is deliberately a local
    # descriptor backed by the durable worker runtime: the model can request a
    # child, but it cannot choose the parent identity, profile revision, or
    # queue semantics.
    class ChildTaskDispatcher
      TOOL_NAME = 'delegate_child_task'
      MAX_CAPABILITIES = ChildTask::MAX_CAPABILITIES
      MAX_TASK_BYTES = ChildTask::MAX_TASK_BYTES
      MAX_PREVIEW_BYTES = 2 * 1024
      DEFAULT_DEPTH = 1
      DEFAULT_CONCURRENCY = 1
      DESCRIPTION = 'Enqueue one durable child task with a narrowed local capability profile. ' \
                    'Arguments: {"task": "bounded task", "capabilities": ["local:read_file"]}. '

      def initialize(runtime:, profile:)
        unless runtime.respond_to?(:enqueue_child_task)
          raise ArgumentError, 'child task runtime must enqueue durable child tasks'
        end
        unless profile.respond_to?(:profile_id) && profile.respond_to?(:tools_allowed) &&
               profile.respond_to?(:canonical_digest)
          raise ArgumentError, 'child task delegation requires a trusted profile'
        end

        @runtime = runtime
        context = child_context(runtime)
        @parent_profile = parent_profile(profile, context)
        @current_depth = context ? context.fetch(:current_depth) : 0
        @current_policy = context&.slice(:remaining_depth, :remaining_concurrency)
        freeze
      end

      attr_reader :parent_profile

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- validation keeps the complete bounded delegation contract at one gate.
      def validate(descriptor, arguments)
        assert_descriptor!(descriptor)
        if @current_policy&.values&.any?(&:zero?)
          raise ToolPolicyError, 'child delegation budget is exhausted'
        end
        raise ToolArgumentError, "#{TOOL_NAME} arguments must be an object" unless arguments.is_a?(Hash)

        unknown = arguments.keys.map(&:to_s) - %w[task capabilities]
        raise ToolArgumentError, "#{TOOL_NAME} has unknown arguments: #{unknown.join(', ')}" unless unknown.empty?

        task = arguments.fetch('task')
        unless task.is_a?(String) && !task.empty? && task.bytesize <= MAX_TASK_BYTES
          raise ToolArgumentError, "child task must be a non-empty string of at most #{MAX_TASK_BYTES} bytes"
        end

        capabilities = arguments.fetch('capabilities')
        unless capabilities.is_a?(Array) && capabilities.length.between?(1, MAX_CAPABILITIES) &&
               capabilities.all? { |name| name.is_a?(String) && name.match?(/\Alocal:[A-Za-z0-9_\-.]+\z/) }
          raise ToolArgumentError, 'child capabilities must be bounded local capability names'
        end
        if Tamoz::Core.secret_shaped?(task) || Tamoz::Core.secret_shaped?(capabilities)
          raise Tamoz::SensitiveValueError, 'child delegation arguments cannot contain credential-shaped values'
        end

        capabilities = capabilities.map(&:to_s).uniq
        parent_capabilities = @parent_profile.fetch('capabilities')
        unless (capabilities - parent_capabilities).empty?
          raise ToolPolicyError, 'child capabilities exceed parent authority'
        end

        { 'task' => task, 'capabilities' => capabilities.freeze }.freeze
      rescue KeyError => e
        raise ToolArgumentError, "#{TOOL_NAME} requires #{e.key}"
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def execute(descriptor, arguments, context:)
        normalized = validate(descriptor, arguments)
        thread_id = context&.thread_id
        request_id = context&.request_id
        if thread_id.to_s.empty? || request_id.to_s.empty?
          raise ToolPolicyError, 'child delegation requires a durable thread and request identity'
        end

        child = ChildTask.build(
          parent_thread_id: thread_id,
          parent_request_id: request_id,
          task: normalized.fetch('task'),
          capability_profile: {
            'capabilities' => normalized.fetch('capabilities'),
            'authority_revision' => @parent_profile.fetch('authority_revision'),
            'delegation_policy' => delegation_policy
          },
          depth: @current_depth + 1,
          concurrency: DEFAULT_CONCURRENCY
        )
        stored = @runtime.enqueue_child_task(child, parent_profile: @parent_profile)
        "Enqueued durable child #{stored.child_id}"
      end

      def preview(descriptor, arguments)
        normalized = validate(descriptor, arguments)
        text = "Delegate durable child\n#{JSON.generate(Tamoz::Core.canonical(normalized))}"
        text.byteslice(0, MAX_PREVIEW_BYTES)
      end

      def effect_intent(descriptor, arguments)
        normalized = validate(descriptor, arguments)
        {
          'parent_profile_id' => @parent_profile.fetch('profile_id'),
          'authority_revision' => @parent_profile.fetch('authority_revision'),
          'child_request_digest' => Tamoz::Core.digest(
            "tamoz.agent.child.request.v1\n", normalized
          )
        }.freeze
      end

      def approval_required?(_descriptor) = true
      def maximum_effect_output_bytes(_descriptor) = MAX_PREVIEW_BYTES
      def safety(_descriptor, _arguments) = :idempotent

      private

      def assert_descriptor!(descriptor)
        return if descriptor.id == TOOL_NAME

        raise ToolPolicyError, "child dispatcher received #{descriptor.id.inspect}"
      end

      def child_context(runtime)
        return unless runtime.respond_to?(:child_delegation_context)

        runtime.child_delegation_context
      end

      def parent_profile(profile, context)
        capabilities = context&.fetch(:capabilities) || profile.tools_allowed.map { |name| "local:#{name}" }
        max_depth = context ? context.fetch(:current_depth) + context.fetch(:remaining_depth) : DEFAULT_DEPTH
        max_concurrency = context ? context.fetch(:remaining_concurrency) : DEFAULT_CONCURRENCY
        {
          'profile_id' => profile.profile_id,
          'capabilities' => capabilities.freeze,
          'authority_revision' => profile.canonical_digest,
          'max_child_depth' => max_depth,
          'max_child_concurrency' => max_concurrency
        }.freeze
      end

      def delegation_policy
        {
          'remaining_depth' => @parent_profile.fetch('max_child_depth') - (@current_depth + 1),
          'remaining_concurrency' => @parent_profile.fetch('max_child_concurrency') - DEFAULT_CONCURRENCY
        }
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    # The child processes `tamoz start` runs for each channel: one gateway per surface, and the worker beside them.
    module CLIChannelProcesses
      private

      def spawn_children(directory, base, logs)
        children = {}
        child_plan(directory, base).each do |name, (env, args)|
          children[name] = spawn_child(name, env, ['--runtime-dir', directory.path, *args], logs)
        end
        children
      rescue StandardError
        children.each_value { |pid| stop_child(pid) }
        raise
      end

      def child_plan(directory, base)
        gateways = descriptors(directory).to_h do |descriptor|
          kind = channel_kind(descriptor.kind)
          env = ChildEnvironments.gateway_env(base, directory:, vars: gateway_vars(directory, descriptor, base),
                                                    allowed: kind.setup.env_names, speech: descriptor.speech?)
          ["#{descriptor.surface_id}-gateway", [env, ['comms', 'serve', '--surface', descriptor.surface_id]]]
        end
        worker = ChildEnvironments.worker_env(base, directory:, channel_names: channel_names(directory))
        gateways.merge('worker' => [worker, %w[--work-routing worker --json]])
      end

      # Every variable any channel may hold: the worker never gets one, configured or not.
      def channel_names(directory)
        loadable = channel_kinds.values.flat_map do |kind|
          kind.setup.env_names
        rescue CLICommsShared::MissingAdapterError
          []
        end
        (loadable + directory.channels.values.map { |entry| entry.dig('credential_ref', 'name') }).compact.uniq
      end

      # What a surface's gateway holds: its kind's declared variables, as its setup hands them over.
      def gateway_vars(directory, descriptor, base)
        kind = channel_kind(descriptor.kind)
        kind.setup.gateway_env(descriptor:, env: channel_env(kind, base),
                               state_dir: channel_state_dir(directory, descriptor.surface_id))
      end
    end
  end
end

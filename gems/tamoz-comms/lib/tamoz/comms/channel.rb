# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # A channel kind's runtime half, implemented by its adapter gem and driven by the gateway process.
    # :reek:UnusedParameters -- contract signatures; the bodies raise because a seam has nothing to implement.
    module Channel
      # @param descriptor [SurfaceDescriptor]
      # @raise [ValidationError] a setting or rendering option this kind cannot serve.
      def validate!(descriptor)
        raise NotImplementedError
      end

      # @param env [Hash{String=>String}] only the variables the kind's setup names in `env_names`.
      # @param voice [#call, nil] text -> audio bytes, given only when the descriptor's rendering speaks.
      # @return [Connection] nothing is listening or polling yet.
      # @raise [ValidationError] a refused value in `env`.
      def connect(descriptor, env:, voice: nil)
        raise NotImplementedError
      end

      # What `connect` returns; the gateway calls `start` only once it holds the surface's lease.
      module Connection
        # @return [Transport]
        def transport = raise(NotImplementedError)

        # @param floor [Integer, nil] the durable cursor.
        # @param history [Array<Hash>] the surface's delivered outbox rows.
        # @raise [ConnectionError] the connection cannot open (e.g. its port is taken).
        def start(**) = nil

        def stop = nil

        # @return [Float] seconds between the gateway's passes.
        def interval_s = raise(NotImplementedError)
      end
    end

    # A channel kind's operator half: plain data in and out; it never sees the runtime, the store or a model.
    # :reek:UnusedParameters -- contract signatures.
    module ChannelSetup
      # @return [String] one line for `tamoz channel` usage.
      def summary = raise(NotImplementedError)

      # @return [Array<String>] every environment variable this kind may read or hand its gateway.
      def env_names = raise(NotImplementedError)

      # @param existing [Hash, nil] the surface's current config entry, if it was added before.
      # @param state_dir [String] the surface's private folder.
      # @param terminal [#say, #warn, #confirm]
      # @return [Hash, nil] the surface's config entry; nil when there is nothing to save (`--help`).
      # @raise [SetupError] with a message the operator can act on.
      def add(existing:, argv:, env:, state_dir:, terminal:)
        raise NotImplementedError
      end

      # @param poller_free [Boolean] whether no other run holds the surface's lease.
      # @return [Array<Array(String, true|String)>] each check's name and true, or the problem.
      def check(descriptor:, env:, state_dir:, poller_free:)
        raise NotImplementedError
      end

      # What `start` prints once the checks pass; most kinds print nothing.
      def announce(**) = nil

      # @return [Hash{String=>String}] the variables the kind's gateway process holds.
      def gateway_env(env:, **) = env.slice(*env_names)
    end
  end
end

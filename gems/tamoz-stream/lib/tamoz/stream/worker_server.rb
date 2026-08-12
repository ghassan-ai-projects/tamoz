# frozen_string_literal: true

require "tamoz/stream/gen"
require "tamoz/stream/errors"
require "tamoz/stream/episode_worker"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T1.1 (deployment slice, PLAN_TAMOZ_STREAM_BUILD T1.1): the gRPC host for
    # the EpisodeWorker handler — the launcher the deployment never wired.
    # The worker is the SERVER: the stream's WorkerExecutor dials it. This
    # class owns the RpcServer lifecycle (bind → run → stop) so the serving
    # shape is testable and the composition stays out of the handler.
    #
    # Transport: production binds a UDS socket (the socket + mTLS is the
    # trust boundary — the vendored proto and handshake make no claim about
    # the transport); development binds an insecure TCP port.
    class WorkerServer
      class ServerError < StreamError
        CATEGORY = "stream_worker_server"
      end

      # worker: the EpisodeWorker handler. Exactly one of port (a TCP port,
      # 0 = ephemeral) or socket (a UDS path) must be given.
      def initialize(worker:, port: nil, socket: nil, pool_size: 16)
        unless worker.is_a?(EpisodeWorker)
          raise ServerError, "worker server requires an EpisodeWorker"
        end
        unless socket.nil? ^ port.nil?
          raise ServerError, "choose exactly one of socket or port"
        end
        @worker = worker
        @socket = socket
        @port = port
        @server = GRPC::RpcServer.new(pool_size:)
        @bound = nil
        @thread = nil
      end

      attr_reader :port, :socket

      # Binds the listener and starts the server on a background thread.
      # Returns [bound_port_or_socket, thread]; the worker is serving once
      # the thread is alive.
      def start
        @bound = bind
        @thread = Thread.new { run }
        [@bound, @thread]
      end

      # Blocks until the server terminates (SIGTERM/SIGINT or stop). Binds
      # lazily so both shapes work: `start` (bind + background thread) and
      # the bin launcher calling `run` directly.
      def run
        @bound ||= bind
        @server.run_till_terminated
      end

      # Stops the server and joins the serving thread. Tolerates the
      # before-start / already-stopped states (grpc raises "Cannot stop before
      # starting" when run_till_terminated never reached its started phase).
      def stop(wait: 5)
        return unless @started

        @server.stop
      rescue RuntimeError
        # grpc's own lifecycle guard: nothing to stop is not an error here.
      ensure
        @started = false
        @thread&.join(wait) if @thread
      end

      private

      def bind
        @server.handle(@worker)
        @started = true
        @server.add_http2_port(address, :this_port_is_insecure)
      end

      def address
        @socket ? "unix://#{@socket}" : "0.0.0.0:#{@port || 0}"
      end
    end
  end
end

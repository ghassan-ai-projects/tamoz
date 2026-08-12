# frozen_string_literal: true

require "grpc"
require "google/protobuf"

module Tamoz
  module Stream
    # T1.1 (PLAN_TAMOZ_STREAM_BUILD T1.1): the vendored, pinned gRPC stubs
    # for the frozen agenticstream runtime-v1 proto. The generated services
    # file requires its messages by a bare name, so the gen directory is put
    # on the load path while they load. The message/service constants live
    # under Agenticstream::Runtime::V1 (the proto package), NOT under Tamoz.
    #
    # Regenerate with `rake stream:proto`; `rake stream:proto:check` proves
    # the committed stubs match the vendored proto (both run in ci).
    module Gen
      DIR = File.expand_path("gen", __dir__).freeze

      def self.load!
        return if @loaded

        $LOAD_PATH.unshift(DIR) unless $LOAD_PATH.include?(DIR)
        require "runtime-v1_pb"
        require "runtime-v1_services_pb"
        @loaded = true
      end
    end
  end
end

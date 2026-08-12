# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/stream/version"

TamozGemspec.build(
  name: "tamoz-stream",
  version: Tamoz::Stream::VERSION,
  summary: "Streaming input and simulated physical action for Tamoz",
  description: "Validated channel/event/Situation values, the structural StreamStore contract, the connector seam, and the stream-episode worker (gRPC EpisodeWorker service + containment host); the SQLite store lives in tamoz-sqlite.",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Stream::VERSION}"],
    ["grpc", "~> 1.83"],
    ["google-protobuf", "~> 4.35"]
  ]
)

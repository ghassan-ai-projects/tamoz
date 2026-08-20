# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/stream/version"

TamozGemspec.build(
  name: "tamoz-stream",
  version: Tamoz::Stream::VERSION,
  summary: "The supervised episode worker for Tamoz",
  description: "The gRPC EpisodeWorker service (the stream's runtime dials it), the containment host, snapshot verification, the typed Decision builder, the reverse channel (evidence client, outcome subscriber, verification store, approval relay, situation memory), and the artifact manifest/retention. The old P14 streaming-input engine was retired by forward migration (MIGRATION_13).",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Stream::VERSION}"],
    ["grpc", "~> 1.83"],
    ["google-protobuf", "~> 4.35"]
  ],
  # Read at runtime by NotificationContract (live_learning_handlers,
  # outcome_subscriber). The goldens/vectors/proto in contracts/ are dev-only.
  runtime_contracts: ["contracts/notification-contract-v1.json"]
)

# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/scheduler/version"

TamozGemspec.build(
  name: "tamoz-scheduler",
  version: Tamoz::Scheduler::VERSION,
  summary: "Durable scheduling for Tamoz",
  description: "Validated schedule/occurrence values and the structural ScheduleStore contract; the SQLite store lives in tamoz-sqlite.",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Scheduler::VERSION}"]
  ]
)

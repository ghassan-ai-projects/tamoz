# frozen_string_literal: true

require "tamoz/core"
require_relative "scheduler/version"
require_relative "scheduler/errors"
require_relative "scheduler/schedule"
require_relative "scheduler/occurrence"
require_relative "scheduler/grant_intersector"
require_relative "scheduler/scorecard_summary_consumer"
require_relative "scheduler/schedule_store"

module Tamoz
  # P13 — durable scheduling (SCHEDULER_DESIGN).
  #
  # ONE responsibility: durably materialize due occurrences into the existing
  # request inbox. This gem holds the validated values and the structural
  # ScheduleStore contract; `tamoz-sqlite` implements the first store. The gem
  # never executes agent logic, approves actions, retries effects, or reports
  # delivery as execution success.
  module Scheduler
  end
end

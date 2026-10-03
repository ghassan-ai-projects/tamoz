# frozen_string_literal: true

module Tamoz
  module Observability
    module Catalog
      # The registered measurements and the labels each one may carry.
      module Measurements
        LABELS = {
          'tamoz.inbox.depth' => %i[status],
          'tamoz.occurrence.oldest_age_ms' => %i[status],
          'tamoz.effect.blocked' => %i[operation],
          'tamoz.effect.unknown' => %i[operation],
          'tamoz.approval.pending' => [],
          'tamoz.lease.held' => [],
          'tamoz.budget.exhaustions' => %i[budget],
          'tamoz.thread.tombstoned' => [],
          'tamoz.turn.duration_ms' => %i[outcome profile surface],
          'tamoz.plan.attempts' => %i[kind outcome],
          'tamoz.review.rejected' => %i[reason_class],
          'tamoz.approval.wait_ms' => %i[outcome],
          'tamoz.model.call.duration_ms' => %i[provider model outcome],
          'tamoz.model.tokens' => %i[provider model kind],
          'tamoz.model.cache.epoch_changed' => %i[reason],
          'tamoz.tool.call.duration_ms' => %i[tool source outcome],
          'tamoz.tool.denied' => %i[tool source reason_class],
          'tamoz.effect.attempts' => %i[operation safety outcome],
          'tamoz.store.commit_ms' => %i[namespace_kind],
          'tamoz.store.busy_retries' => [],
          'tamoz.lease.wait_ms' => [],
          'tamoz.lease.lost' => [],
          'tamoz.verify.outcome' => %i[result],
          'tamoz.repair.attempts' => %i[outcome],
          'tamoz.stop.safe' => %i[reason_class],
          'tamoz.telemetry.dropped' => %i[signal reason lane],
          'tamoz.telemetry.divergence' => %i[reason_class],
          'tamoz.telemetry.export' => %i[outcome]
        }.freeze

        module_function

        def seed(catalog)
          LABELS.each { |name, labels| catalog.measurement(name, since: 1, stability: :stable, labels:) }
        end
      end
    end
  end
end

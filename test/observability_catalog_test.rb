# frozen_string_literal: true

require_relative 'test_helper'

class ObservabilityCatalogTest < Minitest::Test
  Catalog = Tamoz::Observability::Catalog
  SignalCatalog = Tamoz::Observability::SignalCatalog

  def test_seeded_catalog_registers_every_published_name
    expected = %w[
      tamoz.model.call tamoz.tool.call
      tamoz.agent.model.prepare tamoz.agent.model.start
      tamoz.agent.model.finish tamoz.agent.model.ambiguous
      tamoz.agent.tool.prepare tamoz.agent.tool.finish
      tamoz.agent.compatibility.failure
      tamoz.worker.started tamoz.worker.stopped tamoz.worker.error
      tamoz.worker.request.completed tamoz.worker.request.failed tamoz.worker.request.paused
      tamoz.worker.request.stopped tamoz.worker.request.approved tamoz.worker.request.denied
      tamoz.worker.request.claimed tamoz.worker.request.recovered
      tamoz.worker.schedule.materialized tamoz.worker.schedule.error
      comms.started comms.authenticated comms.stopped
      comms.inbound.admitted comms.inbound.duplicate
      comms.inbound.rejected comms.inbound.quarantined
      comms.request.enqueued
      comms.decision.recorded comms.decision.refused
      comms.delivery.sent comms.delivery.throttled comms.delivery.failed
      comms.delivery.unknown comms.delivery.coalesced comms.delivery.dropped
      comms.offset.persisted
      tamoz.inbox.depth tamoz.occurrence.oldest_age_ms tamoz.effect.blocked tamoz.effect.unknown
      tamoz.approval.pending tamoz.lease.held tamoz.budget.exhaustions tamoz.thread.tombstoned
      tamoz.turn.duration_ms tamoz.plan.attempts tamoz.review.rejected tamoz.approval.wait_ms
      tamoz.model.call.duration_ms tamoz.model.tokens tamoz.model.cache.epoch_changed
      tamoz.tool.call.duration_ms tamoz.tool.denied tamoz.effect.attempts tamoz.store.commit_ms
      tamoz.store.busy_retries tamoz.lease.wait_ms tamoz.lease.lost tamoz.verify.outcome
      tamoz.repair.attempts tamoz.stop.safe tamoz.telemetry.dropped tamoz.telemetry.divergence
      tamoz.telemetry.export
    ]

    assert_equal expected.sort, Catalog.names
  end

  def test_seeded_model_call_declares_its_shape
    entry = Catalog.fetch('tamoz.model.call')

    assert_equal [:event, :stable, 1], [entry.kind, entry.stability, entry.since]
    refute entry.safety_bearing
    assert_equal %i[thread_id execution_id request_id task_id], entry.correlation
  end

  def test_seeded_safety_bearing_flags
    assert Catalog.fetch('tamoz.agent.model.ambiguous').safety_bearing
    assert Catalog.fetch('comms.delivery.unknown').safety_bearing
    refute Catalog.fetch('comms.delivery.sent').safety_bearing
  end

  def test_unregistered_name_lookup_raises
    error = assert_raises(Tamoz::Observability::UnregisteredSignalError) do
      Catalog.fetch('tamoz.nobody.registered.this')
    end

    assert_includes error.message, 'not a registered signal'
  end

  def test_duplicate_registration_raises
    catalog = SignalCatalog.new
    definition = {
      since: 1, stability: :stable, safety_bearing: false,
      correlation: %i[thread_id], required: { outcome: :enum }
    }
    catalog.event('tamoz.test.dup', **definition)

    assert_raises(Tamoz::Observability::DuplicateSignalError) do
      catalog.event('tamoz.test.dup', **definition)
    end
  end

  def test_attribute_set_change_without_a_version_bump_raises
    catalog = SignalCatalog.new
    catalog.event(
      'tamoz.test.evolve', since: 1, stability: :stable, safety_bearing: false,
                           correlation: [], required: { outcome: :enum }
    )

    assert_raises(Tamoz::Observability::SchemaEvolutionError) do
      catalog.event(
        'tamoz.test.evolve', since: 1, stability: :stable, safety_bearing: false,
                             correlation: [], required: { outcome: :enum, reason: :low_cardinality }
      )
    end
  end

  def test_attribute_set_change_with_a_version_bump_registers_a_revision
    catalog = SignalCatalog.new
    catalog.event(
      'tamoz.test.evolve', since: 1, stability: :stable, safety_bearing: false,
                           correlation: [], required: { outcome: :enum }
    )
    catalog.event(
      'tamoz.test.evolve', since: 2, stability: :stable, safety_bearing: false,
                           correlation: [], required: { outcome: :enum, reason: :low_cardinality }
    )

    entry = catalog.fetch('tamoz.test.evolve')

    assert_equal 2, entry.since
    assert_equal({ outcome: :enum, reason: :low_cardinality }, entry.required)
  end

  def test_a_metric_cannot_declare_a_correlation_identifier_as_a_label
    catalog = SignalCatalog.new

    %i[thread_id execution_id request_id occurrence_id task_id effect_key span_id trace_id].each do |identifier|
      assert_raises(Tamoz::Observability::ValidationError, identifier.to_s) do
        catalog.measurement('tamoz.test.metric', since: 1, stability: :stable, labels: [identifier])
      end
    end

    entry = catalog.measurement('tamoz.test.metric', since: 1, stability: :stable, labels: %i[provider outcome])

    assert_equal :measurement, entry.kind
  end

  def test_names_outside_the_permitted_prefixes_are_rejected
    catalog = SignalCatalog.new

    assert_raises(Tamoz::Observability::ValidationError) do
      catalog.event('rogue.thing', since: 1, stability: :stable, safety_bearing: false,
                                   correlation: [], required: {})
    end
    assert_raises(Tamoz::Observability::ValidationError) do
      catalog.event('NOT A NAME', since: 1, stability: :stable, safety_bearing: false,
                                  correlation: [], required: {})
    end
  end

  def test_low_cardinality_values_are_bounded
    signal = Tamoz::Observability::Signal.build(
      kind: :event,
      name: 'tamoz.worker.error',
      correlation: {},
      timing: :point,
      observed_at_ms: 1,
      attributes: {reason: 'error message with unbounded detail'}
    )

    assert_raises(Tamoz::Observability::ValidationError) do
      Catalog.validate_signal(signal)
    end
  end
end

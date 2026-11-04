# frozen_string_literal: true

require_relative 'session_context_controls_harness'

module SessionContextControlsReports
  include SessionContextControlsHarness

  private

  def compact_audit(record)
    before, after = record.values_at('before_digest', 'after_digest')
    {
      control: record.fetch('control'),
      digest_formats: [before, after].map { |digest| DIGEST_FORMAT.match?(digest) },
      digests_distinct: before != after,
      mode: record.fetch('compaction_mode'),
      truncated_fragments: record.fetch('truncated_fragments'),
      summary_digest: record.fetch('summary_digest')
    }
  end

  def reference_facts(store, record)
    reference = record.fetch('artifact_refs').fetch(0)
    {
      tenant: reference.fetch('tenant'),
      provenance: reference.fetch('provenance'),
      bytes_externalized: store.resolve(reference.fetch('digest')).fetch('bytes').include?('pppp')
    }
  end

  def usage_facts(document)
    {
      control: document.fetch('control'),
      turn_requests: document.fetch('requests').fetch('turn'),
      resumed: document.fetch('requests').fetch('resume', 0) >= 1,
      no_pinned_budgets: document.fetch('pinned_budgets').empty?,
      observation_ceiling: document.dig('observation_bytes', 'ceiling'),
      reported_keys: %w[tokens cost].select { |key| document.key?(key) }
    }
  end

  def context_facts(document)
    projected = JSON.generate(document)
    {
      control: document.fetch('control'),
      no_preferences: document.fetch('preferences').empty?,
      goal_authoritative: document.dig('layers', 'authoritative_keys').include?('goal'),
      leaked: ['set value to 2', 'value is 2'].select { |text| projected.include?(text) }
    }
  end
end

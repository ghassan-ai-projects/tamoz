# frozen_string_literal: true

require 'json'

module Tamoz
  module Observability
    module Diagnosis
      REPORT_FORMAT_VERSION = 1

      Report = Data.define(
        :generated_at_ms, :since_ms, :rules_digest, :sources, :journal, :degraded_reasons, :summary, :findings
      ) do
        def degraded? = !degraded_reasons.empty?

        def to_h
          Diagnosis.redact({
                             'format_version' => REPORT_FORMAT_VERSION,
                             'generated_at_ms' => generated_at_ms,
                             'since_ms' => since_ms,
                             'rules_digest' => rules_digest,
                             'degraded' => degraded?,
                             'degraded_reasons' => degraded_reasons,
                             'sources' => sources,
                             'journal' => journal,
                             'summary' => summary,
                             'findings' => findings.map(&:to_h)
                           })
        end

        def to_json(*) = JSON.generate(to_h)
      end
    end
  end
end

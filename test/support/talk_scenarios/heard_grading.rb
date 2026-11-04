# frozen_string_literal: true

module TalkScenarios
  module HeardGrading
    VALID_VERDICT_OUTCOMES = %i[pass fail].freeze

    def grade_heard(rows)
      rows.map do |row|
        next row.merge(outcome: :invalid) if row[:hypothesis].nil?

        reference = script(row.fetch(:script))
        row.merge(outcome: :graded, wer: TalkChecks.wer(reference.fetch('text'), row[:hypothesis]),
                  slots: reference.fetch('slots').map { |forms| TalkChecks.slot?(forms, row[:hypothesis]) })
      end
    end

    def heard_summary(name, rows)
      rules = config(name)
      graded = grade_heard(rows)
      valid = graded.reject { |row| row[:outcome] == :invalid }
      return { verdict: 'SHORT', renderings: 0, invalid: graded.length } if valid.empty?

      exact = heard_exact(valid, rules)
      { renderings: valid.length, invalid: graded.length - valid.length, **exact.transform_values { |v| v.round(3) },
        worst: heard_worst(valid), verdict: heard_verdict(rules, exact) }
    end

    def heard_exact(valid, rules)
      slots = valid.flat_map { |row| row[:slots] }
      share_max = rules.fetch('share_wer_max', 0.15)
      { median_wer: median(valid.map { |row| row[:wer] }),
        share_within: valid.count { |row| row[:wer] <= share_max }.fdiv(valid.length),
        slot_rate: slots.count(true).fdiv([slots.length, 1].max), slots: slots.length }
    end

    def heard_worst(valid)
      valid.max_by(2) { |row| row[:wer] }.map { |row| row.slice(:script, :voice, :wer, :hypothesis) }
    end

    def heard_verdict(rules, exact)
      return 'REPORT' if rules['report_only']

      met = exact[:median_wer] <= rules.fetch('median_wer_max') && exact[:share_within] >= rules.fetch('share_min') &&
            exact[:slot_rate] >= rules.fetch('slot_min')
      return 'FAIL' unless met

      exact[:slots] < rules.fetch('min_slots') ? 'SHORT' : 'PASS'
    end

    # A gated scenario passes only at its stated valid runs, with INVALID at most a bounded share of its attempts.
    def verdict(outcomes, needs:, threshold:, max_invalid_share:)
      valid = outcomes.count { |outcome| VALID_VERDICT_OUTCOMES.include?(outcome) }
      return 'SHORT' if valid.zero?
      return 'FAIL' if outcomes.count(:pass).fdiv(valid) < threshold
      return 'SHORT' if valid < needs || outcomes.count(:invalid) > outcomes.length * max_invalid_share

      'PASS'
    end

    def median(values)
      sorted = values.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def grade_heard_link(row)
      return result('heard_end_to_end', row[:script], :invalid, 'no Heard') unless row[:heard]

      same = TalkChecks.normalize(row[:heard]) == TalkChecks.normalize(row[:direct].to_s)
      result('heard_end_to_end', row[:script], same ? :pass : :fail, same ? nil : "#{row[:heard]} ≠ #{row[:direct]}")
    end
  end
end

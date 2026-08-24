# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Classification
        # P12 §3 proof surface: the classification matrix with DENOMINATORS per
        # class. `cases` is [{record:, expected_family:}]; the report is pure data
        # so `tamoz-evals` (builder B/the matrix owner) can consume it without a
        # second implementation.
        # :reek:TooManyStatements — `tally!` records one counter per axis of the
        # proof, `report` assembles the published fields, and `abstention_quality`
        # computes both components with their denominators. Each list IS the
        # surface being proved; shortening one would drop a number a reader needs.
        # :reek:LongParameterList — `quality` takes both rates and both
        # denominators because reporting a rate without its denominator is exactly
        # what this surface exists to avoid.
        # :reek:FeatureEnvy :reek:DuplicateMethodCall — the tally buckets are
        # plain hashes being accumulated; the data is the subject.
        # :reek:DataClump — (per_category, rule) is the tally under construction
        # plus the rule it is being proved against. They travel together for one
        # `run` and are gone after it; a value object here would outlive the
        # computation it exists for.
        module Matrix
          module_function

          def run(cases:, rule:)
            per_category = empty_tally
            cases.each { |entry| tally!(per_category, entry, rule) }
            report(per_category, rule)
          end

          # Every category starts at zero so the report has a DENOMINATOR for each
          # one, including the categories no case exercised. A missing row and a
          # row of zeroes mean different things to whoever reads the proof.
          def empty_tally
            FailureRecord::CATEGORIES.to_h do |category|
              [category.to_s, {
                'denominator' => 0, 'classified' => 0, 'abstained' => 0,
                'correct' => 0, 'mutating' => 0, 'never_mutate' => 0
              }]
            end
          end

          def tally!(per_category, entry, rule)
            record = entry.fetch(:record)
            result = Classification.classify(record, rule:)
            bucket = per_category.fetch(record.category.to_s)
            bucket['denominator'] += 1
            bucket[result.abstained ? 'abstained' : 'classified'] += 1
            bucket['correct'] += 1 if result.action_family == entry.fetch(:expected_family)
            bucket['mutating'] += 1 if result.mutating?
            bucket['never_mutate'] += 1 if result.never_mutate
          end

          def report(per_category, rule)
            buckets = per_category.values
            denominator = buckets.sum { |bucket| bucket['denominator'] }
            abstained = buckets.sum { |bucket| bucket['abstained'] }
            correct = buckets.sum { |bucket| bucket['correct'] }

            {
              'per_category' => per_category,
              'denominator' => denominator,
              'abstained' => abstained,
              'correct' => correct,
              'abstention_rate' => rate(abstained, denominator),
              'precision' => rate(correct, denominator),
              'abstention_quality' => abstention_quality(per_category, rule:),
              'rule_id' => rule.rule_id,
              'rule_version' => rule.version
            }
          end

          # An empty denominator reports 0.0 rather than raising or omitting the
          # field: a proof surface with a missing number is worse than one that
          # says "nothing was measured".
          def rate(numerator, denominator)
            denominator.zero? ? 0.0 : numerator.fdiv(denominator)
          end

          # C9: correct abstention on never-mutate classes MINUS over-abstention on
          # the classes the rule must handle. In -1.0..1.0; only the components are
          # claimed, and both denominators are reported.
          def abstention_quality(per_category, rule:)
            handled = rule.trigger_categories.map(&:to_s)
            never = FailureRecord::NEVER_MUTATE_CATEGORIES.map(&:to_s)

            never_denominator = sum_field(per_category, never, 'denominator')
            never_correct = correct_abstentions(per_category, never)
            handled_denominator = sum_field(per_category, handled, 'denominator')
            over_abstained = sum_field(per_category, handled, 'abstained')

            quality(rate(never_correct, never_denominator), never_denominator,
                    rate(over_abstained, handled_denominator), handled_denominator)
          end

          def correct_abstentions(per_category, never_categories)
            never_categories.sum do |name|
              bucket = per_category.fetch(name)
              bucket['denominator'] - bucket['mutating']
            end
          end

          def sum_field(per_category, names, field)
            names.sum { |name| per_category.fetch(name).fetch(field) }
          end

          # Both components are reported alongside the score, with their own
          # denominators, so a reader can see what the number is made of.
          def quality(correct_rate, never_denominator, over_rate, handled_denominator)
            {
              'score' => correct_rate - over_rate,
              'correct_abstention_rate' => correct_rate,
              'correct_abstention_denominator' => never_denominator,
              'over_abstention_rate' => over_rate,
              'over_abstention_denominator' => handled_denominator
            }
          end
        end
      end
    end
  end
end

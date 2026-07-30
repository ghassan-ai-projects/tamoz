# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteTraceRecorder
        class SelectorDeriver
          def initialize(scenario:, events:, registry:)
            @scenario = scenario
            @events = events
            @registry = registry
          end

          def derive
            grouped = @events.group_by { |event| semantic_key(event) }
            selectors = grouped.flat_map do |(key, entries)|
              selections(entries).map do |event, iteration_class|
                selector(event, iteration_class, key)
              end
            end
            selectors.sort_by! { |selector| selector.fetch("selector_digest") }
            reject_duplicate_coverage!(selectors)
            digests = selectors.map { |selector| selector.fetch("selector_digest") }
            unless digests.uniq.length == digests.length
              raise ExecutionError, "SQLite selectors contain duplicate digests"
            end
            DeepFreeze.call(selectors)
          end

          private

          def semantic_key(event)
            statement = event.fetch("statement")
            template = if statement
                         @registry.resolve_statement(
                           event.fetch("operation"),
                           statement
                         ).fetch("template")
                       end
            [
              event.fetch("point"),
              event.fetch("operation"),
              template,
              attempt_class(event.fetch("attempt"))
            ].freeze
          end

          def selections(entries)
            case entries.length
            when 1
              [[entries.fetch(0), "single"]]
            when 2
              [
                [entries.fetch(0), "first"],
                [entries.fetch(1), "final"]
              ]
            else
              [
                [entries.fetch(0), "first"],
                [entries.fetch((entries.length - 1) / 2), "middle"],
                [entries.fetch(-1), "final"]
              ]
            end
          end

          def selector(event, iteration_class, semantic_key)
            body = {
              "scenario" => @scenario,
              "point" => event.fetch("point"),
              "operation" => event.fetch("operation"),
              "statement" => event.fetch("statement"),
              "attempt_class" => semantic_key.fetch(3),
              "occurrence" => event.fetch("occurrence"),
              "iteration_class" => iteration_class
            }
            body["selector_digest"] = CanonicalJSON.content_digest(
              body,
              domain: "eval.sqlite_selector"
            )
            DeepFreeze.call(body)
          end

          def attempt_class(attempt)
            return "first" if attempt == 1

            raise ExecutionError,
                  "Phase 2 selectors require the first transaction attempt"
          end

          def reject_duplicate_coverage!(selectors)
            identities = Set.new
            selectors.each do |selector|
              statement = selector.fetch("statement")
              template = if statement
                           @registry.resolve_statement(
                             selector.fetch("operation"),
                             statement
                           ).fetch("template")
                         end
              identity = [
                selector.fetch("scenario"),
                selector.fetch("point"),
                selector.fetch("operation"),
                template,
                selector.fetch("attempt_class"),
                selector.fetch("iteration_class")
              ]
              unless identities.add?(identity)
                raise ExecutionError,
                      "SQLite selectors contain duplicate coverage identities"
              end
            end
          end
        end

        private_constant :SelectorDeriver
      end
    end
  end
end

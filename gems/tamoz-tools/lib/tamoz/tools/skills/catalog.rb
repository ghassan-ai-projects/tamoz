# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # =========================================================================
      # Catalog — stage 1 of progressive disclosure
      # =========================================================================
      # :reek:FeatureEnvy — the renderers read the record, entry or string they are
      # handed and turn it into a line; the data is the subject.
      # :reek:TooManyStatements — `resolve` is the ambiguity ladder (exact id,
      # qualified miss, zero, one, many-with-binding, many) and `render` is the
      # ordered assembly of the catalog; each list is the contract.
      # :reek:UtilityFunction — `collision_line` is a pure formatter.
      class Catalog
        attr_reader :snapshot

        def initialize(snapshot)
          raise Error, 'catalog requires a Tamoz::Agent::Skills::SkillSnapshot' unless snapshot.is_a?(SkillSnapshot)

          @snapshot = snapshot
          @bound = snapshot.collisions.to_h { |entry| [entry.name, entry.bound_to] }.freeze
          @by_name = snapshot.records.values.group_by(&:name).freeze
          freeze
        end

        def empty? = @snapshot.empty?

        # A bare name resolves only when it is unambiguous or explicitly bound.
        # Ambiguity is a typed, visible error naming every candidate: never a
        # silent pick (invariant 41).
        def resolve(reference)
          text = String(reference)
          records = @snapshot.records
          record = records[text]
          return record if record

          # A source-qualified id either matches exactly or has no candidates at
          # all; only a bare name can be ambiguous, so only a bare name searches.
          candidates = text.include?('/') ? [] : @by_name.fetch(text, [])
          case candidates.length
          when 0 then raise unknown_skill(text)
          when 1 then candidates.first
          else resolve_ambiguous(text, candidates, records)
          end
        end

        # A bound source wins outright; otherwise the ambiguity is reported with
        # every candidate named, so the operator can qualify it themselves.
        def resolve_ambiguous(text, candidates, records)
          bound = @bound[text]
          return records.fetch(bound) if bound

          raise ToolArgumentError,
                "skill_name_ambiguous: #{Skills.describe(text)} is provided by " \
                "#{candidates.map(&:id).sort.join(', ')}; load it by source-qualified id"
        end

        # One message for both ways a skill can be absent, so the two cannot drift.
        def unknown_skill(text)
          ToolArgumentError.new("skill_unknown: no skill #{Skills.describe(text)} in this catalog")
        end

        # Deterministic bytes, stable id order, and explicit truncation. No absolute
        # path may appear here (plan §3), and `declared_risk` is labelled as the
        # author's claim, never as a Tamoz classification (plan §3.1).
        def render(budget_bytes: MAX_CATALOG_BYTES)
          lines = @snapshot.records.map { |_, record| record_line(record) }
          lines.concat(@snapshot.collisions.map { |entry| collision_line(entry) })

          rendered = within_budget(lines, budget_bytes)
          omitted = lines.length - rendered.length
          if omitted.positive?
            rendered << "- ... #{omitted} more entries not shown " \
                        "(catalog budget #{budget_bytes} bytes exceeded)"
          end
          summary = rejection_summary
          rendered << summary if summary
          rendered.join("\n")
        end

        # Fills the budget in order and stops at the first line that would exceed
        # it — never reorders and never partially renders a line, so what the
        # model sees is always a prefix of what exists.
        def within_budget(lines, budget_bytes)
          used = 0
          lines.take_while do |line|
            used += line.bytesize + 1
            used <= budget_bytes
          end
        end

        private

        def record_line(record)
          declared = record.version
          version = declared ? " v#{clip(declared, 32)}" : ''
          "- #{record.id} [#{record.source_trust}, declared-risk #{record.declared_risk}]" \
            "#{version}: #{clip(record.description, MAX_CATALOG_DESCRIPTION_BYTES)}"
        end

        def collision_line(entry)
          bound = entry.bound_to
          ambiguity = "- ! #{entry.name} is ambiguous (#{entry.candidates.join(', ')}); "
          return "#{ambiguity}operator bound it to #{bound}" if bound

          "#{ambiguity}load it by source-qualified id"
        end

        def rejection_summary
          rejections = @snapshot.rejections
          return nil if rejections.empty?

          counts = rejections.group_by(&:code).transform_values(&:length).sort
          "- ! #{rejections.length} skill(s) rejected: " \
            "#{counts.map { |code, count| "#{code} x#{count}" }.join(', ')}"
        end

        # Byte budget, character boundary: never cuts a UTF-8 sequence in half.
        def clip(value, limit)
          text = String(value).gsub(/[[:cntrl:]]/, ' ').strip
          return text if text.bytesize <= limit

          truncated = +''
          text.each_char do |char|
            break if truncated.bytesize + char.bytesize > limit

            truncated << char
          end
          "#{truncated} …(truncated)"
        end
      end
    end
  end
end

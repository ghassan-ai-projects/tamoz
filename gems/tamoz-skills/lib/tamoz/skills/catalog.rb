# frozen_string_literal: true

module Tamoz
  module Skills
    # The catalog a model sees (stage 1 of progressive disclosure): one line per skill, collisions flagged, and the
    # rejection count, within a byte budget. Also resolves the name a model or user gives back.
    class Catalog
      attr_reader :snapshot

      def initialize(snapshot)
        raise Error, 'catalog requires a Tamoz::Skills::SkillSnapshot' unless snapshot.is_a?(SkillSnapshot)

        @snapshot = snapshot
        @bound = snapshot.collisions.to_h { |entry| [entry.name, entry.bound_to] }.freeze
        @by_name = snapshot.records.values.group_by(&:name).freeze
        freeze
      end

      def empty? = @snapshot.empty?

      # A bare name resolves only when it is unambiguous or operator-bound; ambiguity never picks silently
      # (invariant 41).
      def resolve(reference)
        text = String(reference)
        @snapshot.records[text] || resolve_name(text)
      end

      # What the model sees is always a prefix of what exists, and the cut is said out loud.
      def render(budget_bytes: MAX_CATALOG_BYTES)
        lines = record_lines + collision_lines
        shown = within_budget(lines, budget_bytes)
        omitted = lines.length - shown.length
        shown << omitted_line(omitted, budget_bytes) if omitted.positive?
        shown << rejection_line unless @snapshot.rejections.empty?
        shown.join("\n")
      end

      private

      def resolve_name(text)
        candidates = text.include?('/') ? [] : @by_name.fetch(text, [])
        return candidates.first if candidates.length == 1

        shown = Skills.describe(text)
        raise Tamoz::Core::ToolArgumentError, "skill_unknown: no skill #{shown} in this catalog" if candidates.empty?

        bound = @bound[text]
        return @snapshot.records.fetch(bound) if bound

        ids = candidates.map(&:id).sort.join(', ')
        raise Tamoz::Core::ToolArgumentError,
              "skill_name_ambiguous: #{shown} is provided by #{ids}; load it by source-qualified id"
      end

      def record_lines = @snapshot.records.values.map { |record| record_line(record) }
      def collision_lines = @snapshot.collisions.map { |entry| collision_line(entry) }

      def within_budget(lines, budget_bytes)
        used = 0
        lines.take_while { |line| (used += line.bytesize + 1) <= budget_bytes }
      end

      # The risk is labelled as the author's claim, never as a Tamoz classification.
      def record_line(record)
        version = record.version
        version = version ? " v#{clip(version, 32)}" : ''
        "- #{record.id} [#{record.source_trust}, declared-risk #{record.declared_risk}]#{version}: " \
          "#{clip(record.description, MAX_CATALOG_DESCRIPTION_BYTES)}"
      end

      def collision_line(entry)
        head = "- ! #{entry.name} is ambiguous (#{entry.candidates.join(', ')}); "
        bound = entry.bound_to
        bound ? "#{head}operator bound it to #{bound}" : "#{head}load it by source-qualified id"
      end

      def omitted_line(count, budget_bytes)
        "- ... #{count} more entries not shown (catalog budget #{budget_bytes} bytes exceeded)"
      end

      def rejection_line
        rejections = @snapshot.rejections
        counts = rejections.group_by(&:code).transform_values(&:length).sort
        "- ! #{rejections.length} skill(s) rejected: #{counts.map { |code, count| "#{code} x#{count}" }.join(', ')}"
      end

      # Clips to a byte budget on a character boundary, so a UTF-8 sequence is never cut in half.
      def clip(value, limit)
        text = String(value).gsub(/[[:cntrl:]]/, ' ').strip
        return text if text.bytesize <= limit

        clipped = text.each_char.with_object(+'') do |char, kept|
          break kept if kept.bytesize + char.bytesize > limit

          kept << char
        end
        "#{clipped} …(truncated)"
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Skills
    # Zero silent shadowing (invariant 41): a name two sources share resolves only through an explicit operator
    # binding. Precedence orders the candidates and never picks a winner.
    class Collisions
      def initialize(records, sources, bindings)
        @by_name = records.values.group_by(&:name)
        @precedence = sources.to_h { |source| [source.id, source.precedence] }
        @bindings = bindings
      end

      # The collisions, sorted by name; a binding with nothing to bind is appended to `rejections`.
      def resolve(rejections)
        shared = @by_name.select { |_, candidates| candidates.length > 1 }
        collisions = shared.map { |name, candidates| collision(name, candidates, rejections) }
        @bindings.each do |name, source_id|
          rejections << unsatisfied(source_id, name, 'no collision to bind') unless shared.key?(name)
        end
        collisions.sort_by(&:name)
      end

      private

      def collision(name, candidates, rejections)
        ordered = candidates.sort_by { |record| [@precedence.fetch(record.source_id, 0), record.id] }
        ids = ordered.map(&:id).freeze
        bound = @bindings[name]
        return SkillCollision.new(name:, candidates: ids, bound_to: nil, reason: 'unbound') if bound.nil?

        winner = ordered.find { |record| record.source_id == bound }
        return SkillCollision.new(name:, candidates: ids, bound_to: winner.id, reason: 'operator_binding') if winner

        rejections << unsatisfied(bound, name, 'source did not provide this skill name')
        SkillCollision.new(name:, candidates: ids, bound_to: nil, reason: 'unbound')
      end

      def unsatisfied(source_id, name, detail)
        SkillRejection.new(source_id:, entry: name, code: 'skill_binding_unsatisfied', detail:)
      end
    end
  end
end

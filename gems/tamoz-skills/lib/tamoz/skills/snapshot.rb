# frozen_string_literal: true

module Tamoz
  module Skills
    # Assembles compiled skills into the immutable snapshot a session pins, with the digest that identifies it.
    # :reek:LongParameterList -- the five parts a snapshot is are exactly what its digest covers.
    module Snapshot
      module_function

      def build(records:, collisions:, rejections:, bindings:, sources:)
        ordered = records.sort.to_h
        sorted_rejections = rejections.sort_by { |entry| [entry.source_id, entry.entry, entry.code] }
        digest = catalog_digest(
          records: ordered, collisions:, rejections: sorted_rejections, bindings:, sources:
        )
        SkillSnapshot.new(
          records: ordered.freeze,
          collisions: collisions.freeze,
          rejections: sorted_rejections.freeze,
          bindings:,
          sources:,
          catalog_digest: digest,
          epoch: "skills:#{SNAPSHOT_FORMAT_VERSION}:#{digest}".freeze
        ).freeze
      end

      # Source *roots* are excluded (relocation is not an identity change, and no
      # absolute path may enter a digest input). `SkillRejection#detail` is excluded
      # so a free-text message can never churn an otherwise unchanged epoch.
      def catalog_digest(records:, collisions:, rejections:, bindings:, sources:)
        Skills.digest_of(
          CATALOG_DIGEST_DOMAIN,
          JSON.generate(
            Skills.canonical(
              'format_version' => SNAPSHOT_FORMAT_VERSION,
              'sources' => sources.map { |entry| [entry.id, entry.trust, entry.precedence] },
              'records' => records.map { |id, record| [id, record.tree_digest] },
              'collisions' => collisions.map { |entry| [entry.name, entry.candidates, entry.bound_to] },
              'rejections' => rejections.map { |entry| [entry.source_id, entry.entry, entry.code] },
              'bindings' => bindings
            )
          )
        )
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Skills
    # Compiles configured skill sources into one deterministic snapshot. One bad skill becomes a recorded
    # rejection, never an aborted snapshot.
    class Compiler
      attr_reader :sources, :bindings, :limits

      def initialize(sources: [], bindings: {}, limits: LIMITS)
        raise Error, 'sources must be an Array of Tamoz::Skills::SkillSource' unless valid_sources?(sources)
        raise Error, "at most #{limits.fetch(:max_sources)} skill sources are supported" if
          sources.length > limits.fetch(:max_sources)
        raise Error, 'skill source ids must be distinct' unless sources.map(&:id).uniq.length == sources.length
        raise Error, 'bindings must be a Hash of skill name => source id' unless valid_bindings?(bindings)

        @sources = sources.sort_by(&:id).freeze
        @bindings = Tamoz::Core.deep_freeze(bindings.dup)
        @limits = limits
      end

      def compile
        records = {}
        rejections = []
        @sources.each { |source| compile_source(source, records, rejections) }
        collisions = Collisions.new(records, @sources, @bindings).resolve(rejections)
        Snapshot.build(records:, collisions:, rejections:, bindings: @bindings, sources: @sources)
      end

      private

      def valid_sources?(sources) = sources.is_a?(Array) && sources.all?(SkillSource)

      def valid_bindings?(bindings)
        bindings.is_a?(Hash) && bindings.all? { |name, source| name.is_a?(String) && source.is_a?(String) }
      end

      # A bad source rejects as '.', a bad skill under its own name; neither stops the others.
      def compile_source(source, records, rejections)
        root = Disk.source_root(source)
        Disk.skill_names(root, @limits.fetch(:max_skills_per_source)).each do |child|
          record = compile_skill(source, root, child)
          records[record.id] = record
        rescue Rejected => e
          rejections << e.rejection(source.id)
        end
      rescue Rejected => e
        rejections << e.rejection(source.id)
      end

      def compile_skill(source, root, child)
        directory = Disk.skill_directory(root, child)
        tree = Tree.new(entries: Walk.new(directory, child, @limits).call)
        raise Rejected.new('skill_manifest_missing', child, 'SKILL.md is absent') unless tree.manifest?

        text = Disk.manifest_text(directory, child, @limits.fetch(:max_manifest_bytes))
        manifest = Manifest.new(text, child, @limits)
        Disk.unmoved!(directory, child)
        SkillRecord.new(**identity(source, root, directory), **content(manifest), **digests(manifest, tree))
      end

      def identity(source, root, directory)
        source_id = source.id
        name = File.basename(directory)
        { id: "#{source_id}/#{name}", name:, source_id:, source_trust: source.trust, source_root: root, directory: }
      end

      def content(manifest)
        fields = manifest.fields
        metadata = fields.fetch('metadata')
        { version: metadata['version'], description: fields.fetch('description'), license: fields['license'],
          compatibility: fields['compatibility'], declared_risk: metadata.fetch('tamoz.risk', DEFAULT_DECLARED_RISK),
          metadata: Tamoz::Core.deep_freeze(metadata), extra: Tamoz::Core.deep_freeze(fields.fetch('extra')),
          requested_capabilities: Tamoz::Core.deep_freeze(fields.fetch('allowed-tools')),
          body: manifest.body.dup.freeze }
      end

      def digests(manifest, tree)
        fields = manifest.fields
        { manifest_digest: Tamoz::Core.digest(MANIFEST_DIGEST_DOMAIN, fields.fetch('raw')),
          description_digest: Skills.digest_of(DESCRIPTION_DIGEST_DOMAIN, fields.fetch('description')),
          tree_digest: tree.digest, resource_index: tree.resource_index }
      end
    end
  end
end

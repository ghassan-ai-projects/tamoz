# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # Compiles configured skill trees into one deterministic snapshot.
      # :reek:DataClump — source/root/child and directory/frontmatter/body are the
      # identity and content of one skill as it advances through ordered phases.
      # :reek:DuplicateMethodCall — repeated reads pin validation inputs locally;
      # re-reading the filesystem is intentional at the final TOCTOU boundary.
      # :reek:FeatureEnvy — boundary validation necessarily examines input values.
      # :reek:LongParameterList — `build_record` receives the seven validated parts
      # of the immutable record; a one-use carrier would only rename that tuple.
      # :reek:MissingSafeMethod — each bang is a refusal boundary that raises the
      # existing `Rejected` error; predicate twins would invite ignored failures.
      # :reek:NilCheck — an absent binding has distinct, stable collision semantics.
      # :reek:TooManyMethods — methods name the compiler's existing ordered phases;
      # splitting the orchestration across more stateful objects adds no consumer.
      # :reek:TooManyStatements — each remaining method is one ordered gauntlet or
      # immutable value construction whose first error and mutation timing matter.
      # :reek:UncommunicativeVariableName — RuboCop requires `e` for rescued errors.
      # :reek:UtilityFunction — pure shape/digest helpers belong with this compiler.
      class Compiler
        attr_reader :sources, :bindings, :limits

        def initialize(sources: [], bindings: {}, limits: LIMITS)
          validate_sources!(sources, limits)
          validate_bindings!(bindings)

          @sources = sources.sort_by(&:id).freeze
          @bindings = Tamoz::Core.deep_freeze(bindings.dup)
          @limits = limits
        end

        def compile
          records = {}
          rejections = []
          @sources.each { |source| compile_source(source, records, rejections) }
          collisions = resolve_collisions(records, rejections)
          Snapshot.build(
            records:, collisions:, rejections:, bindings: @bindings, sources: @sources
          )
        end

        private

        def validate_sources!(sources, limits)
          unless sources.is_a?(Array) && sources.all?(SkillSource)
            raise Error, 'sources must be an Array of Tamoz::Agent::Skills::SkillSource'
          end

          max_sources = limits.fetch(:max_sources)
          raise Error, "at most #{max_sources} skill sources are supported" if sources.length > max_sources

          ids = sources.map(&:id)
          raise Error, 'skill source ids must be distinct' unless ids.uniq == ids
        end

        def validate_bindings!(bindings)
          unless bindings.is_a?(Hash) &&
                 bindings.all? { |name, source| name.is_a?(String) && source.is_a?(String) }
            raise Error, 'bindings must be a Hash of skill name => source id'
          end
        end

        def compile_source(source, records, rejections)
          root = source_root(source, rejections)
          return unless root

          children = source_children(source, root, rejections)
          return unless children

          children.each do |child|
            record = compile_skill(source, root, child)
            records[record.id] = record
          rescue Rejected => e
            rejections << SkillRejection.new(
              source_id: source.id, entry: e.entry, code: e.code, detail: e.detail
            )
          end
        end

        def source_root(source, rejections)
          root = File.realpath(source.root)
          return root if File.directory?(root) && !File.lstat(root).symlink?

          reject_source(rejections, source, 'skill_source_not_directory', 'source root is not a directory')
          nil
        rescue SystemCallError
          reject_source(rejections, source, 'skill_source_unavailable', 'source root is unavailable')
          nil
        end

        def source_children(source, root, rejections)
          children = Dir.children(root).sort
          max_skills = @limits.fetch(:max_skills_per_source)
          return children if children.length <= max_skills

          reject_source(rejections, source, 'skill_source_limit', "source holds more than #{max_skills} entries")
          nil
        end

        def reject_source(rejections, source, code, detail)
          rejections << SkillRejection.new(source_id: source.id, entry: '.', code:, detail:)
        end

        def compile_skill(source, root, child)
          directory = validate_skill_directory!(root, child)
          entries = Walk.new(directory, child, @limits).call
          require_manifest!(entries, child)
          fields, frontmatter, body = compile_manifest(directory, child)
          validate_compiled_manifest!(directory, child, fields, frontmatter, body)
          build_record(source, root, child, directory, entries, fields, body)
        end

        def validate_skill_directory!(root, child)
          unless valid_component?(child)
            raise Rejected.new('skill_name_invalid', Skills.describe(child), 'invalid directory name')
          end

          directory = File.join(root, child)
          stat = File.lstat(directory)
          unless stat.directory?
            raise Rejected.new('skill_entry_type_invalid', child, "#{stat.ftype} is not a skill directory")
          end
          unless NAME_PATTERN.match?(child)
            raise Rejected.new('skill_name_invalid', child, 'directory name is not a skill name')
          end
          unless File.realpath(directory) == directory
            raise Rejected.new('skill_realpath_changed', child, 'skill directory resolves elsewhere')
          end

          directory
        end

        def require_manifest!(entries, child)
          manifest = entries.find { |entry| entry.fetch(:path) == MANIFEST_BASENAME }
          raise Rejected.new('skill_manifest_missing', child, 'SKILL.md is absent') unless manifest
        end

        def compile_manifest(directory, child)
          text = read_manifest(File.join(directory, MANIFEST_BASENAME), child)
          frontmatter, body = split_frontmatter(text, child)
          fields = Frontmatter.new(frontmatter, child, @limits).call
          [fields, frontmatter, body]
        end

        def validate_compiled_manifest!(directory, child, fields, frontmatter, body)
          name = fields.fetch('name')
          unless name == child
            raise Rejected.new(
              'skill_name_mismatch', child, "frontmatter name #{Skills.describe(name)} != directory"
            )
          end
          validate_manifest_body!(frontmatter, body, child)
          return if File.realpath(directory) == directory

          raise Rejected.new('skill_realpath_changed', child, 'skill directory resolves elsewhere')
        end

        def validate_manifest_body!(frontmatter, body, child)
          max_body = @limits.fetch(:max_body_bytes)
          if body.bytesize > max_body
            raise Rejected.new(
              'skill_body_bytes_exceeded', child,
              "body is #{body.bytesize} bytes, limit #{max_body}"
            )
          end
          return unless body.include?(DELIMITER_SENTINEL) || frontmatter.include?(DELIMITER_SENTINEL)

          raise Rejected.new(
            'skill_delimiter_forgery', child, 'content contains the attribution delimiter'
          )
        end

        # These seven values are the already-validated parts a SkillRecord is made
        # from; wrapping them would only rename the tuple for this single call.
        def build_record(source, root, child, directory, entries, fields, body) # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
          index = resource_index(entries)
          metadata = fields.fetch('metadata')
          description = fields.fetch('description')
          SkillRecord.new(
            id: "#{source.id}/#{child}", name: child, source_id: source.id,
            source_trust: source.trust, source_root: root, directory:,
            version: metadata['version'], description:, license: fields['license'],
            compatibility: fields['compatibility'],
            declared_risk: metadata.fetch('tamoz.risk', DEFAULT_DECLARED_RISK),
            metadata: Tamoz::Core.deep_freeze(metadata),
            extra: Tamoz::Core.deep_freeze(fields.fetch('extra')),
            requested_capabilities: Tamoz::Core.deep_freeze(fields.fetch('allowed-tools')),
            body: body.dup.freeze,
            manifest_digest: Tamoz::Core.digest(
              MANIFEST_DIGEST_DOMAIN, fields.fetch('raw')
            ),
            description_digest: Skills.digest_of(DESCRIPTION_DIGEST_DOMAIN, description),
            tree_digest: tree_digest(entries),
            resource_index: index.freeze
          )
        end

        def resource_index(entries)
          entries.each_with_object({}) do |entry, collected|
            next unless entry.fetch(:kind) == 'file'

            path = entry.fetch(:path)
            collected[path] = SkillResource.new(
              path:,
              area: entry.fetch(:area),
              bytes: entry.fetch(:bytes),
              digest: entry.fetch(:digest),
              executable: entry.fetch(:executable)
            )
          end
        end

        # Relative paths only: the same tree at two locations has one identity, and
        # no absolute path can leak through a digest input.
        def tree_digest(entries)
          body = entries.map do |entry|
            [entry.fetch(:path), entry.fetch(:kind), entry[:digest], entry.fetch(:executable)]
          end
          Skills.digest_of(TREE_DIGEST_DOMAIN, JSON.generate(body))
        end

        def read_manifest(path, child)
          stat = File.lstat(path)
          if stat.size > @limits.fetch(:max_manifest_bytes)
            raise Rejected.new(
              'skill_manifest_bytes_exceeded', child,
              "SKILL.md is #{stat.size} bytes, limit #{@limits.fetch(:max_manifest_bytes)}"
            )
          end

          text = File.binread(path).force_encoding(Encoding::UTF_8)
          unless text.valid_encoding? && !text.include?("\0")
            raise Rejected.new('skill_manifest_not_utf8', child, 'SKILL.md is not UTF-8 text')
          end

          text
        rescue SystemCallError
          raise Rejected.new('skill_manifest_missing', child, 'SKILL.md is unavailable')
        end

        def split_frontmatter(text, child)
          unless text.start_with?("---\n", "---\r\n")
            raise Rejected.new('skill_frontmatter_missing', child, 'SKILL.md has no frontmatter')
          end

          rest = text.sub(/\A---\r?\n/, '')
          match = FRONTMATTER_TERMINATOR.match(rest)
          raise Rejected.new('skill_frontmatter_missing', child, 'frontmatter is unterminated') unless match

          frontmatter = rest[0, match.begin(0)]
          if frontmatter.bytesize > @limits.fetch(:max_frontmatter_bytes)
            raise Rejected.new(
              'skill_frontmatter_bytes_exceeded', child,
              "frontmatter is #{frontmatter.bytesize} bytes"
            )
          end

          [frontmatter, rest[match.end(0)..].to_s]
        end

        def valid_component?(value)
          value.is_a?(String) &&
            value.dup.force_encoding(Encoding::UTF_8).valid_encoding? &&
            COMPONENT_PATTERN.match?(value)
        end

        # Zero silent shadowing (invariant 41). A bare name shared by two sources
        # resolves to nothing; `precedence` orders the candidate list and never picks
        # a winner. Only an explicit operator binding can bind a colliding name.
        def resolve_collisions(records, rejections)
          by_name = records.values.group_by(&:name)
          collisions = by_name.filter_map do |name, candidates|
            next if candidates.length < 2

            collision_for(name, candidates, rejections)
          end
          reject_unsatisfied_bindings(by_name, rejections)
          collisions.sort_by(&:name)
        end

        def collision_for(name, candidates, rejections)
          ordered = candidates.sort_by { |record| [source_precedence(record), record.id] }
          ids = ordered.map(&:id).freeze
          bound = @bindings[name]
          return SkillCollision.new(name:, candidates: ids, bound_to: nil, reason: 'unbound') if bound.nil?

          winner = ordered.find { |record| record.source_id == bound }
          return SkillCollision.new(name:, candidates: ids, bound_to: winner.id, reason: 'operator_binding') if winner

          rejections << SkillRejection.new(
            source_id: bound, entry: name, code: 'skill_binding_unsatisfied',
            detail: 'source did not provide this skill name'
          )
          SkillCollision.new(name:, candidates: ids, bound_to: nil, reason: 'unbound')
        end

        def reject_unsatisfied_bindings(by_name, rejections)
          @bindings.each_key do |name|
            next if by_name.key?(name) && by_name.fetch(name).length > 1

            rejections << SkillRejection.new(
              source_id: @bindings.fetch(name), entry: name,
              code: 'skill_binding_unsatisfied', detail: 'no collision to bind'
            )
          end
        end

        def source_precedence(record)
          @sources.find { |source| source.id == record.source_id }&.precedence || 0
        end
      end
    end
  end
end

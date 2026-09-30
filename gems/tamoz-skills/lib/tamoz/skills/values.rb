# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # The base is the core taxonomy, never an agent constant: this module runs
      # in a clean environment with only tamoz-core loaded (P16-05).
      class Error < Tamoz::Core::ToolError
      end

      # One configured skill root and its trust/precedence identity.
      SkillSource = Data.define(:id, :root, :trust, :precedence) do
        def initialize(id:, root:, trust:, precedence: 0)
          unless id.is_a?(String) && SOURCE_ID_PATTERN.match?(id)
            raise Error, "skill source id must match #{SOURCE_ID_PATTERN.inspect}"
          end

          normalized_trust = trust.to_s
          raise Error, "skill source trust must be one of #{TRUSTS.join(', ')}" \
            unless TRUSTS.include?(normalized_trust)

          raise Error, 'skill source precedence must be a non-negative Integer' \
            unless precedence.is_a?(Integer) && !precedence.negative?

          super(
            id: id.dup.freeze,
            root: String(root).dup.freeze,
            trust: normalized_trust.dup.freeze,
            precedence:
          )
        end
      end

      # One immutable resource entry covered by a skill tree digest.
      SkillResource = Data.define(:path, :area, :bytes, :digest, :executable) do
        def initialize(path:, area:, bytes:, digest:, executable:)
          super(
            path: path.dup.freeze, area: area.dup.freeze, bytes:,
            digest: digest.dup.freeze, executable:
          )
        end
      end

      # The compiled immutable identity and content of one accepted skill.
      SkillRecord = Data.define(
        :id, :name, :source_id, :source_trust, :source_root, :directory,
        :version, :description, :license, :compatibility,
        :declared_risk, :metadata, :extra, :requested_capabilities,
        :body, :manifest_digest, :description_digest, :tree_digest, :resource_index
      ) do
        def readable_resources
          resource_index.values.select { |entry| READABLE_AREAS.include?(entry.area) }
        end

        # Deterministic, unguessable-in-advance attribution fence (see DELIMITER_SENTINEL).
        def delimiter_token = tree_digest.delete_prefix('sha256:')[0, 16]
      end

      # A name collision and the deterministic binding decision made for it.
      SkillCollision = Data.define(:name, :candidates, :bound_to, :reason)
      # A rejected source entry retained as auditable compilation evidence.
      SkillRejection = Data.define(:source_id, :entry, :code, :detail)

      # The immutable result of compiling every configured skill source.
      SkillSnapshot = Data.define(
        :records, :collisions, :rejections, :bindings, :sources, :catalog_digest, :epoch
      ) do
        def empty? = records.empty?
        def size = records.length
      end

      # Raised internally by the per-skill compile path; converted to a
      # `SkillRejection` so one bad tree never aborts a snapshot and never vanishes.
      class Rejected < Error
        attr_reader :code, :entry

        def initialize(code, entry, detail = nil)
          @code = code.to_s.freeze
          @entry = entry.to_s.freeze
          super(detail ? "#{@code}: #{detail}" : @code)
        end

        def detail
          text = message.sub(/\A#{Regexp.escape(@code)}: ?/, '')
          text.empty? ? @code : text.byteslice(0, MAX_DETAIL_BYTES).scrub
        end
      end
    end
  end
end

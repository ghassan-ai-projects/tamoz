# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P5/§B6-B9: the skill set an episode may render into its frame. The wire
    # carries ORDERED refs [{name, tree_sha256}], digest-pinned; the worker
    # resolves each skill's text ONLY from the operator-approved source (the
    # injected map — the production seam is the compiled Skills::Snapshot from
    # tamoz-tools) and requires the tree digest to match the rendered bytes. A
    # missing name or a digest mismatch fails closed BEFORE any model call.
    #
    # The canonical skill-set digest binds the ordered list of
    # {name, source_class, tree_digest, rendering_protocol_version} — all
    # wire-carried or compile-time constants, so live and replay compute the
    # same value (the P3 replay contract: the manifest digest is never
    # locally re-derived from mutable state).
    class SkillSet
      DIGEST_DOMAIN = :skill_set
      MAX_REFS = 32
      MAX_NAME_BYTES = 128
      MAX_TEXT_BYTES = 64 * 1024
      RENDERING_PROTOCOL_VERSION = "v1"
      SOURCE_CLASS = "operator"

      SkillRef = Data.define(:name, :tree_digest, :text)

      attr_reader :refs, :digest

      # skill_refs_json: the ordered wire list [{name, tree_sha256}].
      # source: the operator-approved {name => rendered_text} map.
      def self.verify_wire(skill_refs_json, source:)
        refs_json = skill_refs_json.to_s
        refs = if refs_json.empty?
                 []
               else
                 parsed = begin
                   Tamoz::Core.parse_json_strict(refs_json)
                 rescue StandardError
                   raise SkillSetError, "skill_set/not_array"
                 end
                 unless parsed.is_a?(Array)
                   raise SkillSetError, "skill_set/not_array"
                 end
                 parsed
               end
        if refs.length > MAX_REFS
          raise SkillSetError, "skill_set/too_many_refs: #{refs.length}"
        end

        built = refs.map { |raw| build_ref(raw, source) }
        new(built)
      end

      def self.build_ref(raw, source)
        unless raw.is_a?(Hash)
          raise SkillSetError, "skill_set/ref_not_object"
        end

        name = String(raw[:name] || raw["name"])
        tree_digest = String(raw[:tree_sha256] || raw["tree_sha256"])
        unless name.bytesize.between?(1, MAX_NAME_BYTES)
          raise SkillSetError, "skill_set/bad_name: #{name.inspect}"
        end
        tree_digest = Tamoz::Core.normalize_digest(tree_digest)
        unless tree_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise SkillSetError, "skill_set/bad_tree_digest: #{name}"
        end

        text = source[name]
        if text.nil?
          raise SkillSetError, "skill_set/unknown_skill: #{name}"
        end
        if text.bytesize > MAX_TEXT_BYTES
          raise SkillSetError, "skill_set/text_too_large: #{name}"
        end
        expected = "sha256:#{Digest::SHA256.hexdigest(text)}"
        unless expected == tree_digest
          raise SkillSetError,
                "skill_set/tree_digest_mismatch: #{name} " \
                "(the operator-approved text no longer matches the wire ref)"
        end

        SkillRef.new(name:, tree_digest:, text:)
      end
      private_class_method :build_ref

      def initialize(refs)
        names = refs.map(&:name)
        unless names.uniq.length == names.length
          raise SkillSetError, "skill_set/duplicate_name"
        end

        @refs = refs.freeze
        @digest = Tamoz::Core.digest(
          DIGEST_DOMAIN,
          refs.map do |ref|
            {
              "name" => ref.name,
              "source_class" => SOURCE_CLASS,
              "tree_digest" => ref.tree_digest,
              "rendering_protocol_version" => RENDERING_PROTOCOL_VERSION
            }
          end
        )
      end

      def empty? = @refs.empty?
    end
  end
end

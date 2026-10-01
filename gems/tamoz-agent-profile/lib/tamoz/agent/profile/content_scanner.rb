# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The value-level content scan: a recursive walk of the PARSED document
      # refusing four things anywhere they appear — a denied key name, a template
      # interpolation, recognisable secret material, and a high-entropy string
      # that looks like a credential.
      #
      # The companion pass to YamlScanner, and deliberately separate from it:
      # YamlScanner walks the event stream before anything is loaded and refuses
      # constructs (tags, merge keys, aliases), while this walks the loaded
      # structure and refuses CONTENT. A profile is operator-owned configuration
      # that names credentials by reference; a value that looks like a secret is
      # refused rather than stored, because a profile is read, copied and diffed
      # by people.
      #
      # The key path is carried down so a rejection can say where it was, and so
      # the entropy check can exempt the fields whose legitimate values are
      # high-entropy by nature (digests and the like).
      #
      # Pinned by test/agent_profile_test.rb (interpolation, embedded api key,
      # secret value heuristic, entropy exemption).
      #
      # :reek:MissingSafeMethod — `scan!` is a refusal that raises; there is no
      # useful predicate twin for "this document contains a secret".
      class ContentScanner
        # The value-level invariant 24 classification for one (field, value):
        # :none, :secret, or :candidate_secret. The document walk below and the
        # facade's single-field check both read from here.
        def self.classify(field, value)
          return :secret if SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
          return :candidate_secret if ENTROPY_PATTERN.match?(value) && !ENTROPY_EXEMPT_KEYS.include?(field.to_s)

          :none
        end

        def self.call(value, path, key_path = [])
          new(path).scan!(value, key_path)
        end

        def initialize(path)
          @path = path
        end

        def scan!(value, key_path = [])
          case value
          when Hash then scan_mapping!(value, key_path)
          when Array then value.each { |entry| scan!(entry, key_path) }
          when String then scan_string!(value, key_path)
          end
        end

        private

        def scan_mapping!(mapping, key_path)
          mapping.each do |key, entry|
            refuse_denied_key!(key)
            scan!(entry, key_path + [key])
          end
        end

        # A key whose very name says it holds a credential. The profile schema has
        # no such field, so seeing one means the operator is about to store a
        # secret in a file that gets copied and diffed.
        def refuse_denied_key!(key)
          return unless SECRET_KEY_DENYLIST.include?(key)

          raise ValidationError, "#{@path}: key #{key.inspect} is not allowed in profiles"
        end

        def scan_string!(value, key_path)
          if INTERPOLATION_PATTERN.match?(value)
            raise ValidationError,
                  "#{@path}: interpolation is not allowed (at #{key_path.join('.').inspect})"
          end
          case self.class.classify(key_path.last, value)
          when :secret
            raise ValidationError, "#{@path}: embedded secret material is not allowed"
          when :candidate_secret
            raise ValidationError, "#{@path}: high-entropy value rejected as candidate secret"
          end
        end
      end
    end
  end
end

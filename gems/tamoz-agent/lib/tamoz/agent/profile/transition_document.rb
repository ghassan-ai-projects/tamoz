# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The transition registry's document as it comes off disk (§5.4/§6.5).
      # Same split as AdoptionDocument: parsed bytes in, one believability
      # question out, so the registry keeps only its locking and write path.
      #
      # DR-5 D2 backward-compatible READ. v1 documents (the shipped shape,
      # schema_version 1, exact 4-key entries) load unchanged and are never
      # rewritten on read; v2 documents add consumed_by/consumed_at on entries.
      # An entry with any other key set — a partial load, a dropped key, an
      # unknown field — is refused typed rather than partially loaded.
      class TransitionDocument
        SCHEMA_VERSION = 2
        LEGACY_SCHEMA_VERSION = 1
        SCHEMA_VERSIONS = [LEGACY_SCHEMA_VERSION, SCHEMA_VERSION].freeze
        BASE_KEYS = %w[from_digest profile_id reason to_digest].freeze
        CONSUMED_KEYS = %w[consumed_at consumed_by].freeze

        def self.empty
          { 'schema_version' => SCHEMA_VERSION, 'transitions' => {} }
        end

        def initialize(data)
          @data = data
        end

        def valid?
          @data.is_a?(Hash) && SCHEMA_VERSIONS.include?(@data['schema_version']) &&
            threads.is_a?(Hash) && threads.all? { |thread_id, entries| valid_thread?(thread_id, entries) }
        end

        private

        def threads
          @data['transitions']
        end

        # :reek:FeatureEnvy — a predicate over the rows it is handed; the envy is
        # the job.
        def valid_thread?(thread_id, entries)
          thread_id.is_a?(String) && TransitionRegistry::THREAD_PATTERN.match?(thread_id) &&
            entries.is_a?(Array) && entries.all? { |entry| valid_entry?(entry) }
        end

        # :reek:UtilityFunction — see AdoptionDocument#valid_activation?.
        def valid_entry?(entry)
          entry.is_a?(Hash) && valid_keys?(entry) && valid_values?(entry)
        end

        # :reek:UtilityFunction — pure key-set comparison.
        def valid_keys?(entry)
          keys = entry.keys.sort
          keys == BASE_KEYS.sort || keys == (BASE_KEYS + CONSUMED_KEYS).sort
        end

        # :reek:UtilityFunction :reek:FeatureEnvy — pure pattern checks over one
        # entry handed in by the caller.
        def valid_values?(entry)
          PROFILE_ID_PATTERN.match?(entry['profile_id'].to_s) &&
            TransitionRegistry::REASON_PATTERN.match?(entry['reason'].to_s) &&
            DIGEST_PATTERN.match?(entry['from_digest'].to_s) &&
            DIGEST_PATTERN.match?(entry['to_digest'].to_s) &&
            optional_strings?(entry)
        end

        # :reek:UtilityFunction — pure optional-field type check.
        def optional_strings?(entry)
          CONSUMED_KEYS.all? { |key| !entry.key?(key) || entry[key].is_a?(String) }
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    class Profile
      # What a validated profile document BECOMES: one immutable value, deeply
      # frozen, carrying the canonical digest that identifies it.
      #
      # The digest is a DURABLE contract. It is what a session pins itself to,
      # what the adoption registry records, and what a transition names on both
      # sides, so its bytes are part of the on-disk format: `DIGEST_DOMAIN`
      # followed by the canonical JSON of the document. Changing any of that
      # invalidates every recorded adoption and every stored session.
      #
      # `build` deliberately takes the whole validated document and picks fields
      # out of it, rather than being handed a pre-shaped hash — the mapping from
      # document to value is the thing worth having in one place.
      #
      # Pinned by test/agent_profile_test.rb (canonical_digest stable,
      # distinguishes, adoption not in digest) and test/agent_session_test.rb.
      #
      # :reek:FeatureEnvy — `initialize` fills in the one optional member before
      # handing it to Data's own initializer; the hash is the subject.
      # :reek:BooleanParameter :reek:LongParameterList — `build`'s four arguments
      # are the document plus the three facts that are NOT in it (the digest, and
      # whether this came from a repository suggestion or a pinned replay).
      # `pinned:` and `suggestion:` are booleans the caller computes; replacing
      # them with a named provenance would be the honest fix and is an API
      # change, so it is a **Q4 candidate**, not part of a move.
      Fields = Data.define(
        :profile_id, :profile_version, :canonical_root, :description,
        :model_roles, :budgets, :checks, :tools_allowed,
        :policy, :canonical_digest, :suggestion, :pinned, :egress
      ) do
        def initialize(pinned: false, **members)
          members[:egress] = nil unless members.key?(:egress)
          super(pinned:, **Profile.deep_freeze(members))
        end

        # Builds the value from a validated document. `canonical_root` is
        # resolved through realpath here and nowhere else, so every consumer sees
        # the same spelling of the same directory.
        def self.build(hash, digest:, suggestion:, pinned: false)
          profile = hash.fetch('profile')
          tools = hash.fetch('tools')
          new(
            profile_id: profile.fetch('profile_id'),
            profile_version: profile.fetch('profile_version'),
            canonical_root: File.realpath(File.expand_path(profile.fetch('canonical_root'))),
            description: profile['description'],
            model_roles: hash['model_roles'] || {},
            budgets: hash['budgets'] || {},
            checks: canonical_checks(hash),
            tools_allowed: tools.fetch('allowed'),
            policy: hash.fetch('policy'),
            canonical_digest: digest,
            suggestion:,
            pinned:,
            egress: hash['egress']
          )
        end

        # Only argv and safety survive into the value: a check's other fields are
        # validation input, not authority.
        def self.canonical_checks(hash)
          (hash['checks'] || {}).transform_values do |check|
            { 'argv' => check.fetch('argv'), 'safety' => check.fetch('safety') }
          end
        end

        def allow_changes? = policy.fetch('allow_changes')

        def high_risk? = model_roles.values.any? { |role| role.key?('credential_ref') }
      end
    end
  end
end

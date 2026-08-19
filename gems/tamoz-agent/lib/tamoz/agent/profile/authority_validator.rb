# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The three interlocking sections that decide what a session may DO:
      # `tools` (what this profile permits at all), `unattended` (what may run
      # with nobody watching), and `policy` (the versions and switches that bind
      # them). They are one responsibility because they constrain each other —
      # unattended may only name tools that are allowed, and policy.allow_changes
      # false must contradict any action tool being allowed.
      #
      # Deliberately THREE entry points rather than one `call`, because the loader
      # does not run them together: `unattended!` runs early in validate_schema!,
      # against the raw document, while `tools!` and `policy!` run later and
      # `policy!` consumes what `tools!` returned. Collapsing them into one
      # sequence would change which error a bad profile reports first, and the
      # first error is what an operator sees.
      #
      # Pinned by test/agent_profile_test.rb (allow_changes vs action tools,
      # unknown fields) and test/agent_profile_machinery_test.rb.
      #
      # :reek:MissingSafeMethod — every entry point is a refusal that raises;
      # there is no predicate form of an authority contradiction.
      # :reek:NilCheck — absence is a domain value three times over: no unattended
      # section at all, a risk class the profile does not name, and the optional
      # unattended catalog digest. Each nil means "not declared", which is
      # different from "declared empty" and must not be conflated with it.
      # :reek:TooManyStatements :reek:FeatureEnvy — `unattended!` and
      # `validate_risk_class!` walk a section handed to them field by field; the
      # list of refusals IS the schema, and the data they interrogate is the
      # untrusted document, not state of their own.
      class AuthorityValidator
        ACTION_TOOLS = %w[apply_patch create_file run_check].freeze
        MAX_BEHAVIOR_VERSION_BYTES = 64

        def self.tools!(hash, path)
          new(hash, path).tools!
        end

        def self.unattended!(hash, path)
          new(hash, path).unattended!
        end

        def self.policy!(hash, tools, path)
          new(hash, path).policy!(tools)
        end

        def initialize(hash, path)
          @hash = hash
          @path = path
        end

        # Returns the normalized tools mapping the policy check then consumes.
        def tools!
          tools = section('tools', TOOLS_KEYS)
          allowed = tools['allowed']
          unless allowed.is_a?(Array) && !allowed.empty? &&
                 allowed.all? { |name| name.is_a?(String) && KNOWN_TOOLS.include?(name) } &&
                 allowed.uniq == allowed
            raise ValidationError, "#{@path}: tools.allowed must be distinct known tool names"
          end

          { 'allowed' => allowed, 'approval_required' => approval_required(tools, allowed) }
        end

        # The unattended section names tools by RISK CLASS. Every name must be a
        # tool this profile allows: preauthorizing something the profile does not
        # permit is a contradiction, and silently ignoring it would let a profile
        # look more permissive than it is.
        #
        # `forbidden` wins over every other list. A tool named there can never run
        # unattended no matter what else claims it — a deny must not be defeatable
        # by adding the same name somewhere more permissive.
        def unattended!
          section = @hash['unattended']
          return if section.nil?

          raise ValidationError, "#{@path}: unattended must be a mapping" unless section.is_a?(Hash)

          refuse_unknown!(section.keys - UNATTENDED_KEYS, 'unattended')
          allowed = @hash.dig('tools', 'allowed') || []
          UNATTENDED_KEYS.each { |key| validate_risk_class!(section[key], key, allowed) }
        end

        # :reek:TooManyStatements — the policy section's fields, each with its own
        # refusal; the list is the schema.
        def policy!(tools)
          policy = section('policy', POLICY_KEYS)
          validate_allow_changes!(policy, tools)
          unless SAFETIES.include?(policy['default_check_safety'])
            raise ValidationError, "#{@path}: policy.default_check_safety must be one of #{SAFETIES.inspect}"
          end

          validate_graph_version!(policy)
          validate_behavior_version!(policy)
          validate_catalog_digests!(policy)
        end

        private

        # Fetches a required section and refuses any field outside its allowlist.
        def section(key, known_keys)
          value = Profile.required_hash(@hash, key, @path)
          refuse_unknown!(value.keys - known_keys, key)
          value
        end

        def refuse_unknown!(unknown, section_name)
          return if unknown.empty?

          raise ValidationError, "#{@path}: unknown #{section_name} fields #{unknown.sort.inspect}"
        end

        def approval_required(tools, allowed)
          required = tools['approval_required'] || []
          unless required.is_a?(Array) &&
                 required.all? { |name| name.is_a?(String) && allowed.include?(name) } &&
                 required.uniq == required
            raise ValidationError, "#{@path}: tools.approval_required must be a subset of tools.allowed"
          end

          required
        end

        def validate_risk_class!(names, key, allowed)
          return if names.nil?

          unless names.is_a?(Array) && names.all?(String) && names.uniq == names
            raise ValidationError, "#{@path}: unattended.#{key} must be distinct tool names"
          end

          outside = names - allowed
          return if outside.empty?

          raise ValidationError,
                "#{@path}: unattended.#{key} names #{outside.sort.inspect}, which " \
                'tools.allowed does not permit'
        end

        # A profile that forbids changes must not also permit a tool that makes
        # them; the contradiction is refused rather than silently resolved.
        def validate_allow_changes!(policy, tools)
          allow = policy['allow_changes']
          unless [true, false].include?(allow)
            raise ValidationError, "#{@path}: policy.allow_changes must be true or false"
          end
          return if allow
          return unless tools.fetch('allowed').intersect?(ACTION_TOOLS)

          raise ValidationError, "#{@path}: policy.allow_changes is false but action tools are allowed"
        end

        def validate_graph_version!(policy)
          expected = Tamoz::Agent::Session::GRAPH_VERSION
          return if policy['graph_version'] == expected

          raise ValidationError, "#{@path}: policy.graph_version must equal #{expected.inspect}"
        end

        def validate_behavior_version!(policy)
          behavior = policy['behavior_version']
          return if behavior.is_a?(String) && !behavior.empty? &&
                    behavior.bytesize <= MAX_BEHAVIOR_VERSION_BYTES

          raise ValidationError,
                "#{@path}: policy.behavior_version must be a string of at most " \
                "#{MAX_BEHAVIOR_VERSION_BYTES} bytes"
        end

        # The unattended catalog digest is optional (absent is the pre-unattended
        # state); the tool catalog digest is not.
        def validate_catalog_digests!(policy)
          unattended = policy['unattended_catalog_digest']
          if !unattended.nil? && !Tamoz::Core.valid_digest?(unattended)
            raise ValidationError, "#{@path}: policy.unattended_catalog_digest must be a sha256: digest"
          end

          digest = policy['tool_catalog_digest']
          return if Tamoz::Core.valid_digest?(digest)

          raise ValidationError, "#{@path}: policy.tool_catalog_digest must be a sha256: digest"
        end
      end
    end
  end
end

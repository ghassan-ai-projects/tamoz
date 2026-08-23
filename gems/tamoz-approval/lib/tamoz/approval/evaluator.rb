# frozen_string_literal: true

module Tamoz
  module Approval
    # Minimal evaluator used for document simulations in Phase 2; the full
    # Engine in Phase 3 reuses the same evaluation rules.
    class Evaluator
      CLOSED_MATCHERS = %i[verb tool target_glob argv_prefix argv_flag].freeze

      def initialize(document)
        @document = document
      end

      def evaluate(request)
        rule = matching_deny_rule(request)
        return decision_from(rule, request, :deny) if rule

        rule = matching_ask_allow_rule(request)
        return decision_from(rule, request, rule[:verdict]) if rule

        tier = tier_for(request)
        default = tier.fetch(:default)
        decision_for_tier(request, tier, default)
      end

      private

      def matching_deny_rule(request)
        @document.rules.find { |rule| rule[:verdict] == :deny && match?(rule, request) }
      end

      def matching_ask_allow_rule(request)
        @document.rules.find { |rule| rule[:verdict] != :deny && match?(rule, request) }
      end

      def match?(rule, request)
        rule[:match].all? do |matcher, expected|
          case matcher
          when :verb then request.verb == expected
          when :tool then request.tool == expected
          when :target_glob then request.targets.any? { |target| glob_match?(expected, target) }
          when :argv_prefix then request.argv.first(expected.length) == expected
          when :argv_flag then request.argv.include?(expected)
          else false
          end
        end
      end

      def glob_match?(pattern, target)
        File.fnmatch(pattern, target, File::FNM_DOTMATCH | File::FNM_PATHNAME)
      end

      def tier_for(request)
        entry = @document.tool_tiers[request.tool]
        name = if request.effect_class == :read_only
                 :read
               else
                 entry ? entry[:tier] : @document.fallback_tier[:tier]
               end
        @document.tiers.fetch(name).merge(name: name)
      end

      def decision_from(rule, request, verdict)
        tier = tier_for(request)
        build_decision(request, tier, verdict, rule[:reason], rule[:id])
      end

      def decision_for_tier(request, tier, verdict)
        build_decision(request, tier, verdict, "tier #{tier.fetch(:name)} default", "tier.#{tier.fetch(:name)}")
      end

      def build_decision(request, tier, verdict, reason, rule_id)
        Decision.new(
          id: decision_id(request),
          verdict: verdict,
          reason: reason,
          rule_id: rule_id,
          tier: tier.fetch(:name),
          grant_offer: grant_offer_for(request, tier, verdict),
          required_evidence: verdict == :ask ? @document.evidence[:approve] : nil,
          policy_rev: @document.policy_rev
        )
      end

      def grant_offer_for(request, tier, verdict)
        return nil unless verdict == :ask

        scopes = tool_scopes_for(request, tier)
        return nil if scopes.empty?

        key = grant_key_for(request, tier)
        scopes = [:once] if key.nil?

        GrantOffer.new(scopes: scopes, key: key || {})
      end

      def tool_scopes_for(request, tier)
        entry = @document.tool_tiers[request.tool]
        entry&.fetch(:grant_scopes, nil) || tier.fetch(:grant_scopes, [])
      end

      def grant_key_for(request, tier)
        fields = @document.grant_keys[tier.fetch(:name)]
        return nil unless fields

        key = {}
        fields.each do |field|
          value = case field
                  when :verb then request.verb
                  when :tool then request.tool
                  when :target_root then target_root(request)
                  when :key_argv then key_argv(request)
                  else nil
                  end
          return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          key[field] = value
        end
        key
      end

      def target_root(request)
        return nil if request.targets.empty?

        target = request.targets.first
        target = target.delete_prefix('/') while target.start_with?('/')
        target.split('/').first
      end

      def key_argv(request)
        entry = @document.tool_tiers[request.tool]
        positions = entry&.fetch(:key_argv, nil)
        return nil unless positions

        values = positions.map { |index| request.argv[index] }
        return nil if values.any?(&:nil?)

        values
      end

      def decision_id(request)
        "#{request.session_id}:#{@document.policy_rev}:#{request_digest(request)}"
      end

      def request_digest(request)
        Digest::SHA256.hexdigest(canonical_request(request))
      end

      def canonical_request(request)
        JSON.generate(
          tool: request.tool,
          verb: request.verb,
          argv: request.argv,
          targets: request.targets,
          effect_class: request.effect_class
        )
      end
    end
  end
end

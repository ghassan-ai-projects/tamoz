# frozen_string_literal: true

module Tamoz
  module Approval
    # Rules to verdict: deny rules first regardless of document order, then
    # first-match ask/allow, then the tier default. Never raises for a policy
    # reason — an unmatched request falls to the tier machinery.
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
        @document.tier_for(request.tool, request.effect_class)
      end

      def decision_from(rule, request, verdict)
        tier = tier_for(request)
        build_decision(request:, tier:, verdict:, reason: rule[:reason], rule_id: rule[:id])
      end

      def decision_for_tier(request, tier, verdict)
        name = tier.fetch(:name)
        build_decision(request:, tier:, verdict:, reason: "tier #{name} default", rule_id: "tier.#{name}")
      end

      def build_decision(request:, tier:, verdict:, reason:, rule_id:)
        Decision.new(
          id: decision_id(request),
          verdict: verdict,
          reason: reason,
          rule_id: rule_id,
          tier: tier.fetch(:name),
          grant_offer: grant_offer_for(request, tier, verdict),
          required_evidence: verdict == :ask ? @document.evidence[:approve] : nil,
          policy_rev: @document.policy_rev,
          session_id: request.session_id
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
        entry = @document.tool_entry(request.tool)
        # An unclassified tool takes its scopes from fallback_tier itself —
        # the field the loader validates — never from the tier map, or a
        # document could hand :session to tools it never classified.
        return @document.fallback_tier[:grant_scopes] if entry.nil?

        entry.fetch(:grant_scopes, nil) || tier.fetch(:grant_scopes, [])
      end

      def grant_key_for(request, tier)
        fields = @document.grant_keys[tier.fetch(:name)]
        return nil unless fields

        # Key fields are opaque equality tokens; stringifying them here makes
        # the durable (JSON-serialized) grant form identical to the in-memory
        # one.
        key = {}
        fields.each do |field|
          value = case field
                  when :verb then request.verb.to_s
                  when :tool then request.tool.to_s
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
        # Every presented target folds into the key: one approval must cover
        # exactly the paths the human saw, so a second, unseen target forces
        # a fresh ask.
        request.targets.map { |target| path_root(target) }.uniq.sort
      end

      def path_root(target)
        component = target
        component = component.delete_prefix('/') while component.start_with?('/')
        component.split('/').first
      end

      def key_argv(request)
        entry = @document.tool_entry(request.tool)
        positions = entry&.fetch(:key_argv, nil)
        return nil unless positions

        values = positions.map { |index| request.argv[index] }
        return nil if values.any?(&:nil?)

        values
      end

      def decision_id(request)
        "#{request.session_id}:#{@document.policy_rev}:#{Canonical.hexdigest(canonical_request(request))}"
      end

      def canonical_request(request)
        {
          tool: request.tool,
          verb: request.verb,
          argv: request.argv,
          targets: request.targets,
          effect_class: request.effect_class
        }
      end
    end
  end
end

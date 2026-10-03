# frozen_string_literal: true

module Tamoz
  module Approval
    # The structural rules a loaded policy document must satisfy before any verdict is read from it.
    class PolicyValidator
      def initialize(document, evidence_symbols)
        @document = document
        @evidence_symbols = evidence_symbols
      end

      def validate!
        validate_tool_tiers!
        validate_fallback_tier!
        validate_tiers!
        validate_rules!
        validate_evidence!
      end

      private

      def validate_tool_tiers!
        @document.tool_tiers.each { |tool, entry| validate_tool_tier!(tool, entry) }
      end

      def validate_tool_tier!(tool, entry)
        validate_tool_pattern!(tool)
        tier = entry[:tier]
        raise InvalidPolicyError, "tool_tiers #{tool} references unknown tier #{tier}" unless tiers.key?(tier)

        validate_tool_session_scope!(tool, tier, entry[:grant_scopes] || tiers[tier][:grant_scopes])
      end

      def validate_tool_pattern!(tool)
        return unless tool.to_s.include?('*') && !tool.to_s.match?(/\A[^*]+\*\z/)

        raise InvalidPolicyError, "tool_tiers #{tool} may use * only as a final prefix wildcard"
      end

      def validate_tool_session_scope!(tool, tier, scopes)
        if tier == :local_execute && tool == :child_task && scopes.include?(:session)
          raise InvalidPolicyError, "tool_tiers #{tool} grant_scopes may not include :session"
        end
        return unless scopes.include?(:session) && !no_session_scope?(tier)
        return if grant_keys[tier]

        raise InvalidPolicyError,
              "tool_tiers #{tool} maps to #{tier} with :session but grant_keys has no " \
              "#{tier} entry; the scope could never be minted"
      end

      def validate_fallback_tier!
        fallback = @document.fallback_tier
        unless tiers.key?(fallback[:tier])
          raise InvalidPolicyError, "fallback_tier references unknown tier #{fallback[:tier]}"
        end
        return unless fallback[:grant_scopes].include?(:session)

        raise InvalidPolicyError, 'fallback_tier grant_scopes may not include :session'
      end

      def validate_tiers!
        tiers.each do |name, tier|
          validate_verdict!(tier[:default], "tier #{name} default")
          validate_tier_session_scope!(name, tier[:grant_scopes])
        end
      end

      def validate_tier_session_scope!(name, scopes)
        if no_session_scope?(name) && scopes.include?(:session)
          raise InvalidPolicyError, "tier #{name} grant_scopes may not include :session"
        end
        return unless scopes.include?(:session)
        return if grant_keys[name]

        raise InvalidPolicyError,
              "tier #{name} advertises :session but grant_keys has no #{name} entry; " \
              'the scope could never be minted'
      end

      def validate_rules!
        @document.rules.each do |rule|
          validate_verdict!(rule[:verdict], "rule #{rule[:id]} verdict")
          unknown = rule[:match].keys - PolicyDocument::CLOSED_MATCHERS
          raise InvalidPolicyError, "rule #{rule[:id]} uses unknown matchers #{unknown}" unless unknown.empty?
        end
      end

      def validate_evidence!
        @document.evidence.each_value do |symbol|
          next if @evidence_symbols.include?(symbol)

          raise InvalidPolicyError, "evidence symbol #{symbol.inspect} is not in the injected symbol set"
        end
      end

      def validate_verdict!(verdict, subject)
        return if PolicyDocument::CLOSED_VERDICTS.include?(verdict)

        raise InvalidPolicyError, "#{subject} must be one of #{PolicyDocument::CLOSED_VERDICTS}"
      end

      def no_session_scope?(tier)
        PolicyDocument::NO_SESSION_SCOPE_TIERS.include?(tier)
      end

      def tiers
        @document.tiers
      end

      def grant_keys
        @document.grant_keys
      end
    end

    private_constant :PolicyValidator
  end
end

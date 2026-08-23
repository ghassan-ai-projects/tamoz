# frozen_string_literal: true

require 'digest'
require 'json'
require 'yaml'

module Tamoz
  module Approval
    class PolicyDocument
      CLOSED_VERDICTS = %i[allow ask deny].freeze
      CLOSED_MATCHERS = Evaluator::CLOSED_MATCHERS
      NO_SESSION_SCOPE_TIERS = %i[network external_publish destructive].freeze

      attr_reader :path, :policy_rev, :version, :tool_tiers, :fallback_tier,
                  :tiers, :grant_keys, :rules, :ask, :evidence, :simulations,
                  :profile_name

      def self.load(path, evidence_symbols:, simulator: nil)
        new(path: path, evidence_symbols: evidence_symbols, simulator: simulator)
      end

      def initialize(path:, evidence_symbols:, simulator: nil)
        @path = path
        @evidence_symbols = evidence_symbols
        @simulator = simulator || Evaluator.new(self)
        raw = load_yaml(path)
        @version = fetch_key(raw, 'version')
        @tool_tiers = normalize_tool_tiers(fetch_key(raw, 'tool_tiers'))
        @fallback_tier = normalize_fallback_tier(fetch_key(raw, 'fallback_tier'))
        @tiers = normalize_tiers(fetch_key(raw, 'tiers'))
        @grant_keys = fetch_key(raw, 'grant_keys').transform_keys(&:to_sym).transform_values { |fields| fields.map(&:to_sym) }
        @rules = normalize_rules(fetch_key(raw, 'rules'))
        @ask = normalize_ask(fetch_key(raw, 'ask'))
        @evidence = normalize_evidence(fetch_key(raw, 'evidence'))
        @simulations = normalize_simulations(fetch_key(raw, 'simulations'))
        recompute_digest_and_validate!
      rescue KeyError, NoMethodError, Errno::ENOENT, Errno::EISDIR, Errno::EACCES,
             Psych::Exception, TypeError, SystemStackError => error
        raise InvalidPolicyError, "policy document structure error in #{@path}: #{error.class}: #{error.message}"
      end

      def self.load_profile(base_path, profile_name, evidence_symbols:, simulator: nil)
        base = load(base_path, evidence_symbols: evidence_symbols, simulator: simulator)
        base.send(:apply_profile, profile_name)
      rescue InvalidPolicyError
        raise
      rescue KeyError, NoMethodError, Errno::ENOENT, Errno::EISDIR, Errno::EACCES,
             Psych::Exception, TypeError, SystemStackError => error
        raise InvalidPolicyError,
              "profile #{profile_name.inspect} could not be applied to #{base_path}: #{error.class}: #{error.message}"
      end

      # The structural rule has one home (ADR §7): an unclassified tool falls
      # to the fallback tier no matter what its descriptor claims; a
      # classified :read_only tool lands in tier read even over contradicting
      # data.
      def tier_for(tool, effect_class)
        entry = tool_tiers[tool]
        name = if entry.nil?
                 fallback_tier[:tier]
               elsif effect_class.to_sym == :read_only
                 :read
               else
                 entry[:tier]
               end
        tiers.fetch(name).merge(name: name)
      end

      def verb_for(tool, effect_class)
        entry = tool_tiers[tool]
        return fallback_tier[:verb] if entry.nil?
        return :read if effect_class.to_sym == :read_only

        entry[:verb]
      end

      private

      def fetch_key(hash, key)
        hash.fetch(key)
      rescue KeyError
        raise InvalidPolicyError, "missing required key #{key.inspect} in #{@path}"
      end

      def apply_profile(profile_name)
        profile_path = profile_path_for(profile_name)
        raw = load_yaml(profile_path)
        profile = raw.fetch('profile')
        unless profile.fetch('name') == profile_name
          raise InvalidPolicyError, "profile name mismatch: #{profile.fetch('name').inspect} != #{profile_name.inspect}"
        end

        # A mode may restate the canned expectations its defaults actually
        # guarantee: base pins unknown-tool ask, which a deny-all or allow-most
        # tier overlay legitimately changes. Absent key keeps base's block.
        allowed_keys = %w[name tier_defaults on_timeout simulations]
        unknown = profile.keys - allowed_keys
        unless unknown.empty?
          raise InvalidPolicyError, "profile #{profile_name} contains unknown keys: #{unknown.join(', ')}"
        end

        @profile_name = profile_name
        apply_tier_defaults(profile['tier_defaults'])
        apply_on_timeout(profile['on_timeout'])
        apply_simulations(profile['simulations'])
        recompute_digest_and_validate!
        self
      end

      def load_yaml(path)
        YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
      rescue Psych::SyntaxError => error
        raise InvalidPolicyError, "YAML syntax error: #{error.message}"
      end

      def normalize_tool_tiers(raw)
        raw.transform_keys(&:to_sym).transform_values do |entry|
          {
            tier: entry.fetch('tier').to_sym,
            verb: entry.fetch('verb').to_sym,
            key_argv: entry['key_argv']&.map(&:to_i),
            grant_scopes: entry['grant_scopes']&.map(&:to_sym)
          }.compact
        end
      end

      def normalize_fallback_tier(raw)
        {
          tier: raw.fetch('tier').to_sym,
          verb: raw.fetch('verb').to_sym,
          grant_scopes: raw.fetch('grant_scopes', []).map(&:to_sym)
        }
      end

      def normalize_tiers(raw)
        raw.transform_keys(&:to_sym).transform_values do |entry|
          {
            default: entry.fetch('default').to_sym,
            grant_scopes: entry.fetch('grant_scopes', []).map(&:to_sym)
          }
        end
      end

      def normalize_rules(raw)
        raw.map do |entry|
          match = {}
          entry.fetch('match').each do |key, value|
            sym_key = key.to_sym
            match[sym_key] = case sym_key
                             when :verb, :tool then value.to_sym
                             when :argv_prefix then value.map(&:to_s)
                             else value.to_s
                             end
          end
          {
            id: entry.fetch('id'),
            match: match,
            verdict: entry.fetch('verdict').to_sym,
            reason: entry.fetch('reason')
          }
        end
      end

      def normalize_ask(raw)
        on_timeout = raw.fetch('on_timeout').to_sym
        unless %i[park deny].include?(on_timeout)
          raise InvalidPolicyError, "ask.on_timeout must be :park or :deny, got #{raw.fetch('on_timeout').inspect}"
        end
        {
          timeout_s: raw.fetch('timeout_s'),
          on_timeout: on_timeout
        }
      end

      def normalize_evidence(raw)
        raw.transform_keys(&:to_sym).transform_values(&:to_sym)
      end

      def normalize_simulations(raw)
        raw.map do |entry|
          request = {}
          entry.fetch('request').each do |key, value|
            sym_key = key.to_sym
            request[sym_key] = case sym_key
                               when :tool, :verb then value.to_sym
                               when :argv, :targets then value.map(&:to_s)
                               else value.to_s
                               end
          end
          {
            request: request,
            expect: entry.fetch('expect').to_sym
          }
        end
      end

      def compute_digest(value)
        Canonical.hexdigest(value)
      end

      def validate!
        validate_tool_tiers!
        validate_fallback_tier!
        validate_tiers!
        validate_rules!
        validate_evidence!
      end

      def validate_tool_tiers!
        @tool_tiers.each do |tool, entry|
          tier = entry[:tier]
          raise InvalidPolicyError, "tool_tiers #{tool} references unknown tier #{tier}" unless @tiers.key?(tier)

          scopes = entry[:grant_scopes] || @tiers[tier][:grant_scopes]
          if tier == :local_execute && tool == :child_task && scopes.include?(:session)
            raise InvalidPolicyError, "tool_tiers #{tool} grant_scopes may not include :session"
          end
          next unless scopes.include?(:session) && !NO_SESSION_SCOPE_TIERS.include?(tier)

          unless @grant_keys[tier]
            raise InvalidPolicyError,
                  "tool_tiers #{tool} maps to #{tier} with :session but grant_keys has no " \
                  "#{tier} entry; the scope could never be minted"
          end
          if NO_SESSION_SCOPE_TIERS.include?(tier) && scopes.include?(:session)
            raise InvalidPolicyError, "tool_tiers #{tool} mapped to #{tier}; grant_scopes may not include :session"
          end
        end
      end

      def validate_fallback_tier!
        tier = @fallback_tier[:tier]
        raise InvalidPolicyError, "fallback_tier references unknown tier #{tier}" unless @tiers.key?(tier)
        if @fallback_tier[:grant_scopes].include?(:session)
          raise InvalidPolicyError, 'fallback_tier grant_scopes may not include :session'
        end
      end

      def validate_tiers!
        @tiers.each do |name, tier|
          default = tier[:default]
          raise InvalidPolicyError, "tier #{name} default must be one of #{CLOSED_VERDICTS}" unless CLOSED_VERDICTS.include?(default)

          scopes = tier[:grant_scopes]
          if NO_SESSION_SCOPE_TIERS.include?(name) && scopes.include?(:session)
            raise InvalidPolicyError, "tier #{name} grant_scopes may not include :session"
          end
          next unless scopes.include?(:session)

          unless @grant_keys[name]
            raise InvalidPolicyError,
                  "tier #{name} advertises :session but grant_keys has no #{name} entry; " \
                  "the scope could never be minted"
          end
        end
      end

      def validate_rules!
        @rules.each do |rule|
          raise InvalidPolicyError, "rule #{rule[:id]} verdict must be one of #{CLOSED_VERDICTS}" unless CLOSED_VERDICTS.include?(rule[:verdict])

          unknown = rule[:match].keys - CLOSED_MATCHERS
          raise InvalidPolicyError, "rule #{rule[:id]} uses unknown matchers #{unknown}" unless unknown.empty?
        end
      end

      def validate_evidence!
        @evidence.each_value do |symbol|
          unless @evidence_symbols.include?(symbol)
            raise InvalidPolicyError, "evidence symbol #{symbol.inspect} is not in the injected symbol set"
          end
        end
      end

      def run_simulations!
        @simulations.each do |simulation|
          request = Request.new(
            tool: simulation[:request][:tool],
            verb: simulation[:request][:verb].to_sym,
            argv: simulation[:request].fetch(:argv, []),
            targets: simulation[:request].fetch(:targets, []),
            effect_class: :bounded,
            session_id: 'simulation'
          )
          decision = @simulator.evaluate(request)
          next if decision.verdict == simulation[:expect]

          raise InvalidPolicyError,
                "simulation failed for #{simulation[:request].inspect}: expected #{simulation[:expect]}, got #{decision.verdict}"
        end
      end

      def profile_path_for(profile_name)
        base_dir = File.dirname(@path)
        profile_file = File.join(base_dir, 'profiles', "#{profile_name}.yaml")
        raise InvalidPolicyError, "unknown profile #{profile_name.inspect}" unless File.exist?(profile_file)

        profile_file
      end

      def apply_tier_defaults(overrides)
        return unless overrides

        overrides.each do |tier_name, default|
          name = tier_name.to_sym
          raise InvalidPolicyError, "profile tier_defaults references unknown tier #{name}" unless @tiers.key?(name)

          @tiers[name][:default] = default.to_sym
        end
      end

      def apply_on_timeout(value)
        return unless value

        symbol = value.to_sym
        unless %i[park deny].include?(symbol)
          raise InvalidPolicyError, "profile on_timeout must be :park or :deny, got #{value.inspect}"
        end
        @ask[:on_timeout] = symbol
      end

      def apply_simulations(raw)
        return unless raw

        @simulations = normalize_simulations(raw)
      end

      # The rev digests the NORMALIZED structures, never the raw YAML, so the
      # same effective policy yields the same rev whichever load path built
      # it — a no-op profile overlay must not invalidate live grants.
      def recompute_digest_and_validate!
        @policy_rev = compute_digest(digest_basis)
        validate!
        run_simulations!
      end

      def digest_basis
        {
          'version' => @version,
          'tool_tiers' => @tool_tiers,
          'fallback_tier' => @fallback_tier,
          'tiers' => @tiers,
          'grant_keys' => @grant_keys,
          'rules' => @rules,
          'ask' => @ask,
          'evidence' => @evidence,
          'simulations' => @simulations
        }
      end

    end
  end
end

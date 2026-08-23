# frozen_string_literal: true

require 'optparse'

# Tamoz::Agent::CLI::OptionPolicy — usage rules for the parsed options (Q3
# slice 4). Profile is session authority: it applies only to the durable
# profile-aware commands and replaces the flag-driven capability surface, so
# combining it with --allow-changes/--check is an error. Check commands
# require explicit --allow-changes. Shared by the subcommand router and the
# one-shot path; the profile rules are pinned by test/agent_cli_profile_test.rb
# and the check rule by test/agent_cli_test.rb.
module Tamoz
  module Agent
    class CLI
      # Capability-surface policy over the parsed options hash. Stateless: the
      # rules are the entire purpose of this class.
      class OptionPolicy
        PROFILE_COMMANDS = %w[ask resume continue follow-up follow_up followup redirect profile].freeze
        PROFILE_COMBINATION_ERROR = '--profile sets the capability surface; do not combine it with ' \
                                    '--allow-changes or --check'

        # :reek:FeatureEnvy -- validating these params IS this class's purpose;
        # the rules cannot move to the options hash or the subcommand.
        def validate_profile_usage(options, subcommand)
          return unless options[:profile]

          unless PROFILE_COMMANDS.include?(subcommand)
            raise OptionParser::InvalidArgument, "--profile is not supported for #{subcommand}"
          end
          return unless options[:allow_changes] || options[:checks].any?

          raise OptionParser::InvalidArgument,
                PROFILE_COMBINATION_ERROR
        end

        # :reek:FeatureEnvy -- same stateless-validation rationale as above.
        def validate_check_config(options)
          return if options[:allow_changes] || options[:checks].empty?

          raise OptionParser::InvalidArgument, '--check requires --allow-changes'
        end
      end
    end
  end
end

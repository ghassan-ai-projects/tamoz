# frozen_string_literal: true

module Tamoz
  module Agent
    # The skills an operator asked for on the command line: `--skills DIR`, `--bundled-skills` and `--skill NAME`.
    # Command-line authority is the only place skills come from on the CLI.
    class SkillsOptions
      def initialize(options)
        @root = options[:skills_dir]
        @bundled = options[:bundled_skills] == true
      end

      def snapshot(workspace_root)
        Tamoz::Skills.operator_snapshot(root: @root, workspace_root:, bundled: @bundled)
      end

      # A profile that allows load_skill with no skills configured would build a toolbox missing a tool it pins.
      def snapshot_for(profile)
        skills = snapshot(profile.canonical_root)
        return skills unless skills.empty? && profile.tools_allowed.include?('load_skill')

        raise ArgumentError, "profile #{profile.profile_id} allows load_skill; pass --skills DIR or --bundled-skills"
      end

      # A thread's invoked skill must load now, not fail or vanish at its first model call.
      def self.require_loadable!(toolbox, skill)
        return unless skill
        unless toolbox.names.include?('load_skill')
          raise ArgumentError,
                "--skill #{skill} needs --skills DIR or --bundled-skills, and a profile that allows load_skill"
        end

        toolbox.skill_identity(skill)
      end
    end
  end
end

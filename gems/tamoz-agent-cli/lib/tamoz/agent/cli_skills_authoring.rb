# frozen_string_literal: true

require_relative 'cli_skill_trajectory'

module Tamoz
  module Agent
    # `tamoz skills new|create|promote`: a drafted skill is a staged candidate a person reviews and installs.
    module CLISkillsAuthoring
      include CLISkillTrajectory

      private

      def author_skill(action, options, argv)
        values = parse_authoring_options(argv)
        target = argv.shift
        raise OptionParser::MissingArgument, "skills #{action} #{authoring_target(action)}" if target.to_s.empty?

        case action
        when 'new' then new_skill(target, values[:dir] || Dir.pwd)
        when 'create' then create_skill(target, options, values[:thread])
        else promote_skill(target, options, values[:approver])
        end
      end

      def parse_authoring_options(argv)
        values = {}
        OptionParser.new do |parser|
          parser.on('--dir DIR') { |value| values[:dir] = value }
          parser.on('--from-session THREAD') { |value| values[:thread] = value }
          parser.on('--approver NAME') { |value| values[:approver] = value }
        end.parse!(argv)
        values
      end

      def authoring_target(action)
        action == 'promote' ? 'CANDIDATE_DIR' : 'NAME'
      end

      def new_skill(name, parent)
        @out.puts SkillInstallation.scaffold(name, parent)
        0
      end

      # The creator: a work turn, guided by the bundled skill-authoring skill, drafts the skill from a verified
      # thread into a private staging workspace; the draft is staged only when it meets the authoring bar.
      def create_skill(name, options, thread)
        validate_create_arguments!(name, thread)
        trajectory = verified_trajectory(options, thread)
        stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S')
        workspace = draft_skill_workspace(name, stamp, options, trajectory)
        status = run_drafting_turn(name, stamp, options, workspace)
        # The draft has no check of its own (exit 2, done unverified); the authoring bar at staging is its gate.
        unless [0, 2].include?(status)
          @err.puts "the drafting turn did not finish (exit #{status}); the draft is in #{workspace}"
          return status
        end

        stage_drafted_skill(name, thread, workspace)
      end

      def validate_create_arguments!(name, thread)
        raise OptionParser::MissingArgument, 'skills create NAME --from-session THREAD' if thread.to_s.empty?
        unless Tamoz::Skills::NAME_PATTERN.match?(name)
          raise OptionParser::InvalidArgument, "#{name.inspect} is not a skill name"
        end

        validate_thread_id!(thread)
      end

      def draft_skill_workspace(name, stamp, options, trajectory)
        session_dir = @sessions.provision_session_dir!(options)
        SkillInstallation.draft_workspace(session_dir, "#{name}-#{stamp}", name, trajectory)
      end

      def run_drafting_turn(name, stamp, options, workspace)
        draft_options = options.merge(root: workspace, work_routing: true, allow_changes: true, bundled_skills: true,
                                      skills_dir: nil, skill: 'skill-authoring', checks: {}, session: nil,
                                      profile: nil, explicit_session: "skill-draft-#{name}-#{stamp}".downcase)
        cmd_ask(draft_options,
                ["Write a skill named #{name} into the directory #{name}/ of this workspace, " \
                 'from trajectory.md.'])
      end

      def stage_drafted_skill(name, thread, workspace)
        manifest = SkillInstallation.stage_draft(File.join(workspace, name), created_by: 'tamoz.skill-creator',
                                                                             source: "session:#{thread}")
        @out.puts "staged candidate #{manifest['name']} #{manifest['tree_digest']}"
        @out.puts "review #{File.join(workspace, name)}, then: tamoz skills promote #{File.join(workspace, name)} " \
                  '--approver YOUR-NAME --skills DIR'
        0
      end

      def promote_skill(candidate, options, approver)
        raise OptionParser::MissingArgument, 'skills promote CANDIDATE_DIR --skills DIR' unless options[:skills_dir]
        unless File.directory?(options[:skills_dir])
          raise ArgumentError,
                "skills root #{options[:skills_dir]} does not exist"
        end

        entry = SkillInstallation.new(options[:skills_dir]).install(candidate, approver: approver.to_s)
        @out.puts "installed #{entry['name']} #{entry['tree_digest']}, approved by #{entry['approver']}" \
                  "#{"; previous version kept in #{entry['retired']}" if entry['retired']}"
        0
      end
    end
  end
end

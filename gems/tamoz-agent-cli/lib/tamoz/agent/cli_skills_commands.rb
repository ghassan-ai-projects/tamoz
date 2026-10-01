# frozen_string_literal: true

require 'fileutils'
require 'json'

module Tamoz
  module Agent
    # `tamoz skills list|check|path|show`: what `--skills DIR` / `--bundled-skills` would load. `new`, `create` and
    # `promote` author skills: a drafted skill is a staged candidate a person reviews and installs.
    module CLISkillsCommands
      private

      def cmd_skills(options, argv)
        action = argv.shift || 'list'
        return author_skill(action, options, argv) if %w[new create promote].include?(action)

        snapshot = skills_snapshot(options, options[:root])
        case action
        when 'list' then list_skills(snapshot, options)
        when 'check' then check_skills(snapshot)
        when 'path' then skill_path(snapshot, argv.first)
        when 'show' then show_skill(snapshot, argv.first)
        else raise OptionParser::InvalidArgument, "skills #{action} (expected list, check, path, show, new, create or promote)"
        end
      end

      def list_skills(snapshot, options)
        return (@out.puts(JSON.generate(skills_document(snapshot))) || 0) if options[:json]

        @out.puts 'No skills configured: pass --skills DIR and/or --bundled-skills.' if snapshot.sources.empty?
        snapshot.records.each_value do |record|
          @out.puts "#{record.id} [#{record.source_trust}] #{record.tree_digest}"
          @out.puts "  #{record.description}"
        end
        snapshot.rejections.each { |entry| @out.puts "rejected #{entry.source_id}/#{entry.entry}: #{entry.code} — #{entry.detail}" }
        0
      end

      def check_skills(snapshot)
        issues = snapshot.records.values.flat_map { |record| Tamoz::Skills.lint(record).map { |line| "#{record.id} #{line}" } }
        issues += snapshot.rejections.map { |entry| "#{entry.source_id}/#{entry.entry} rejected: #{entry.code} — #{entry.detail}" }
        issues.each { |line| @out.puts line }
        @out.puts "#{snapshot.records.length} skill(s) meet the bar" if issues.empty?
        issues.empty? ? 0 : 1
      end

      def skill_path(snapshot, name)
        raise OptionParser::MissingArgument, 'skills path NAME' if name.to_s.empty?

        @out.puts Tamoz::Skills::Catalog.new(snapshot).resolve(name).directory
        0
      end

      def show_skill(snapshot, name)
        raise OptionParser::MissingArgument, 'skills show NAME' if name.to_s.empty?

        record = Tamoz::Skills::Catalog.new(snapshot).resolve(name)
        @out.puts "#{record.id} [#{record.source_trust}] #{record.tree_digest}"
        @out.puts "directory: #{record.directory}"
        @out.puts "eval suite: #{record.metadata.fetch('tamoz.eval-suite', 'none')}"
        issues = Tamoz::Skills.lint(record)
        @out.puts "authoring bar: #{issues.empty? ? 'met' : issues.join('; ')}"
        record.resource_index.each_value { |entry| @out.puts "  #{entry.path} (#{entry.bytes} bytes) #{entry.digest}" }
        @out.puts '', record.description, '', record.body
        0
      end

      def author_skill(action, options, argv)
        values = {}
        OptionParser.new do |parser|
          parser.on('--dir DIR') { |value| values[:dir] = value }
          parser.on('--from-session THREAD') { |value| values[:thread] = value }
          parser.on('--approver NAME') { |value| values[:approver] = value }
        end.parse!(argv)
        target = argv.shift
        raise OptionParser::MissingArgument, "skills #{action} #{action == 'promote' ? 'CANDIDATE_DIR' : 'NAME'}" if
          target.to_s.empty?

        case action
        when 'new' then new_skill(target, values[:dir] || Dir.pwd)
        when 'create' then create_skill(target, options, values[:thread])
        else promote_skill(target, options, values[:approver])
        end
      end

      def new_skill(name, parent)
        @out.puts Tamoz::Skills.scaffold(name, parent)
        0
      end

      # The creator: a work turn, guided by the bundled skill-authoring skill, drafts the skill from a verified
      # thread into a private staging workspace; the draft is staged only when it meets the authoring bar.
      def create_skill(name, options, thread)
        raise OptionParser::MissingArgument, 'skills create NAME --from-session THREAD' if thread.to_s.empty?

        trajectory = verified_trajectory(options, thread)
        stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S')
        workspace = File.join(provision_private_session_dir!(options), 'skill-drafts', "#{name}-#{stamp}")
        FileUtils.mkdir_p(workspace, mode: 0o700)
        File.write(File.join(workspace, 'trajectory.md'), trajectory)
        status = cmd_ask(options.merge(root: workspace, work_routing: true, allow_changes: true, bundled_skills: true,
                                       skills_dir: nil, skill: 'skill-authoring', checks: {}, session: nil,
                                       explicit_session: "skill-draft-#{name}-#{stamp}".downcase),
                         ["Write a skill named #{name} into the directory #{name}/ of this workspace, from trajectory.md."])
        return status unless status.zero?

        manifest = Tamoz::Skills.stage_candidate(File.join(workspace, name), created_by: 'tamoz.skill-creator',
                                                                                source: "session:#{thread}")
        @out.puts "staged candidate #{manifest['name']} #{manifest['tree_digest']}"
        @out.puts "review #{File.join(workspace, name)}, then: tamoz skills promote #{File.join(workspace, name)} " \
                  '--approver YOUR-NAME --skills DIR'
        0
      end

      def verified_trajectory(options, thread)
        view = nil
        run_durable(options, thread, read_only: true) { |session, _request_id, _owner_id| view = session.view(thread:) }
        state = view.state
        verification = state[:verification] || {}
        unless state[:terminal_reason] == 'done' && verification['satisfied'] == true
          raise ArgumentError, "thread #{thread} did not finish verified (#{state[:terminal_reason]}); only verified work becomes a skill"
        end

        trajectory_text(state, verification)
      end

      def trajectory_text(state, verification)
        tools = Array(state[:work_entries]).select { |entry| entry['kind'] == 'tool_result' }.map { |entry| entry['name'] }
        checks = Array(state[:work_checks]).map { |check| "#{check['name']}: #{check['passed'] ? 'passed' : 'failed'}" }
        plan = state[:work_plan]
        <<~MARKDOWN
          # Verified trajectory

          ## Task

          #{state[:task]}

          ## Plan

          #{plan ? JSON.pretty_generate(plan) : '(none recorded)'}

          ## Tools used, in order

          #{tools.empty? ? '(none)' : tools.map { |name| "- #{name}" }.join("\n")}

          ## Files changed

          #{Array(state[:work_changes]).uniq.map { |path| "- #{path}" }.join("\n")}

          ## Checks

          #{checks.empty? ? '(none)' : checks.map { |line| "- #{line}" }.join("\n")}

          ## Final answer

          #{verification['answer']}
        MARKDOWN
      end

      def promote_skill(candidate, options, approver)
        raise OptionParser::MissingArgument, 'skills promote CANDIDATE_DIR --skills DIR' unless options[:skills_dir]

        entry = Tamoz::Skills.install_candidate(candidate, skills_root: options[:skills_dir], approver:)
        @out.puts "installed #{entry['name']} #{entry['tree_digest']}, approved by #{entry['approver']}" \
                  "#{entry['retired'] ? "; previous version kept in #{entry['retired']}" : ''}"
        0
      end

      def skills_document(snapshot)
        { 'catalog_digest' => snapshot.catalog_digest,
          'skills' => snapshot.records.values.map do |record|
            { 'id' => record.id, 'trust' => record.source_trust, 'tree_digest' => record.tree_digest,
              'description' => record.description, 'issues' => Tamoz::Skills.lint(record) }
          end,
          'rejections' => snapshot.rejections.map { |entry| entry.to_h.transform_keys(&:to_s) } }
      end
    end
  end
end

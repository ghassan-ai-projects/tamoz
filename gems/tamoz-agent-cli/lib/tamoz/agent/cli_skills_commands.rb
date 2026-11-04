# frozen_string_literal: true

require 'json'
require_relative 'cli_skills_authoring'

module Tamoz
  module Agent
    # `tamoz skills list|check|path|show`: what `--skills DIR` / `--bundled-skills` would load. `new`, `create` and
    # `promote` author skills (CLISkillsAuthoring).
    module CLISkillsCommands
      include CLISkillsAuthoring

      private

      def cmd_skills(options, argv)
        action = argv.shift || 'list'
        return author_skill(action, options, argv) if %w[new create promote].include?(action)

        # Read-only views: nothing here reaches a session, so the workspace rule does not apply.
        snapshot = SkillsOptions.new(options).snapshot(nil)
        case action
        when 'list' then list_skills(snapshot, options)
        when 'check' then check_skills(snapshot)
        when 'path' then skill_path(snapshot, argv.first)
        when 'show' then show_skill(snapshot, argv.first)
        else raise OptionParser::InvalidArgument,
                   "skills #{action} (expected list, check, path, show, new, create or promote)"
        end
      end

      def list_skills(snapshot, options)
        return @out.puts(JSON.generate(skills_document(snapshot))) || 0 if options[:json]

        @out.puts 'No skills configured: pass --skills DIR and/or --bundled-skills.' if snapshot.sources.empty?
        snapshot.records.each_value do |record|
          @out.puts skill_title(record)
          @out.puts "  #{record.description}"
        end
        snapshot.rejections.each { |entry| @out.puts rejection_line(entry) }
        0
      end

      def rejection_line(entry)
        "rejected #{entry.source_id}/#{entry.entry}: #{entry.code} — #{entry.detail}"
      end

      def check_skills(snapshot)
        issues = skill_issues(snapshot)
        issues.each { |line| @out.puts line }
        @out.puts "#{snapshot.records.length} skill(s) meet the bar" if issues.empty?
        issues.empty? ? 0 : 1
      end

      def skill_issues(snapshot)
        issues = snapshot.records.values.flat_map { |record| Tamoz::Skills.lint(record).map { |line| "#{record.id} #{line}" } }
        rejected = snapshot.rejections.map do |entry|
          "#{entry.source_id}/#{entry.entry} rejected: #{entry.code} — #{entry.detail}"
        end
        issues + rejected
      end

      def skill_path(snapshot, name)
        raise OptionParser::MissingArgument, 'skills path NAME' if name.to_s.empty?

        @out.puts Tamoz::Skills::Catalog.new(snapshot).resolve(name).directory
        0
      end

      def show_skill(snapshot, name)
        raise OptionParser::MissingArgument, 'skills show NAME' if name.to_s.empty?

        record = Tamoz::Skills::Catalog.new(snapshot).resolve(name)
        puts_skill_header(record)
        record.resource_index.each_value { |entry| @out.puts "  #{entry.path} (#{entry.bytes} bytes) #{entry.digest}" }
        @out.puts '', record.description, '', record.body
        0
      end

      def puts_skill_header(record)
        @out.puts skill_title(record)
        @out.puts "directory: #{record.directory}"
        @out.puts "eval suite: #{record.metadata.fetch('tamoz.eval-suite', 'none')}"
        issues = Tamoz::Skills.lint(record)
        @out.puts "authoring bar: #{issues.empty? ? 'met' : issues.join('; ')}"
      end

      def skill_title(record)
        "#{record.id} [#{record.source_trust}] #{record.tree_digest}"
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

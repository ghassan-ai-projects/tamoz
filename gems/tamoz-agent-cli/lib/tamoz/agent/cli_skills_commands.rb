# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # `tamoz skills list|check|path NAME`: what the operator's `--skills DIR` / `--bundled-skills` would load.
    module CLISkillsCommands
      private

      def cmd_skills(options, argv)
        action = argv.shift || 'list'
        snapshot = skills_snapshot(options, options[:root])
        case action
        when 'list' then list_skills(snapshot, options)
        when 'check' then check_skills(snapshot)
        when 'path' then skill_path(snapshot, argv.first)
        else raise OptionParser::InvalidArgument, "skills #{action} (expected list, check or path NAME)"
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

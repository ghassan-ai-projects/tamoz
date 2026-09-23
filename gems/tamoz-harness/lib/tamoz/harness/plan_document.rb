# frozen_string_literal: true

require 'pathname'

module Tamoz
  module Harness
    # The living plan written through update_plan: the review object, the scope, and the state that survives compaction.
    class PlanDocument
      STATUSES = %w[pending in_progress done].freeze
      LIST_FIELDS = %w[decisions ruled_out open_questions].freeze
      DIGEST_DOMAIN = "tamoz.harness.plan.v1\n"
      MAX_ITEMS = 40

      attr_reader :document, :digest

      def self.parse(arguments)
        raise PlanError, 'plan must be an object' unless arguments.is_a?(Hash)

        document = {
          'goal' => text!(arguments['goal'], 'goal'),
          'done_when' => list!(arguments['done_when'], 'done_when', min: 1),
          'scope' => scope!(arguments['scope']),
          'steps' => steps!(arguments['steps'])
        }
        LIST_FIELDS.each { |field| document[field] = list!(arguments[field] || [], field) }
        new(document)
      end

      def self.text!(value, name)
        raise PlanError, "#{name} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
        raise PlanError, "#{name} exceeds 2000 characters" if value.length > 2000

        value.strip
      end

      def self.list!(value, name, min: 0)
        unless value.is_a?(Array) && value.length.between?(min, MAX_ITEMS)
          raise PlanError, "#{name} must be a list of #{min}..#{MAX_ITEMS} strings"
        end

        value.map { |item| text!(item, name) }
      end

      def self.scope!(value)
        raise PlanError, 'scope must be an object with paths' unless value.is_a?(Hash)

        { 'paths' => list!(value['paths'], 'scope.paths', min: 1).map { |path| normalize_path!(path) }.uniq.sort,
          'checks' => list!(value['checks'] || [], 'scope.checks').uniq.sort }
      end

      def self.normalize_path!(path)
        if path.match?(/[*?\[\]{}]/)
          raise PlanError,
                "scope path #{path.inspect} must be a concrete path, not a pattern"
        end

        normalized = clean(path)
        raise PlanError, "scope path #{path.inspect} must stay inside the workspace" unless normalized

        normalized
      end

      # The workspace-relative form of a path, or nil when it leaves the workspace.
      def self.clean(path)
        cleaned = Pathname.new(path.to_s).cleanpath.to_s
        return nil if cleaned.start_with?('/') || cleaned == '..' || cleaned.start_with?('../')

        cleaned
      end

      def self.steps!(value)
        raise PlanError, "steps must be a list of 1..#{MAX_ITEMS}" unless value.is_a?(Array) && value.length.between?(
          1, MAX_ITEMS
        )

        value.map do |step|
          raise PlanError, 'each step must be an object' unless step.is_a?(Hash)
          raise PlanError, "step status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(step['status'])

          { 'title' => text!(step['title'], 'step title'), 'status' => step['status'] }
        end
      end
      private_class_method :text!, :list!, :scope!, :normalize_path!, :steps!

      def initialize(document)
        @document = Tamoz::Core.deep_freeze(document)
        @digest = Tamoz::Core.digest(DIGEST_DOMAIN, @document)
        freeze
      end

      def paths = document.fetch('scope').fetch('paths')
      def checks = document.fetch('scope').fetch('checks')

      def in_scope?(path)
        normalized = self.class.clean(path)
        return false unless normalized

        paths.any? { |root| root == '.' || normalized == root || normalized.start_with?("#{root}/") }
      end

      def widens?(previous) = !(paths.all? { |path| previous.in_scope?(path) } && (checks - previous.checks).empty?)

      def done? = document.fetch('steps').all? { |step| step.fetch('status') == 'done' }

      def render
        steps = document.fetch('steps').map { |step| "- [#{step.fetch('status')}] #{step.fetch('title')}" }
        lines = ['# Plan', "Goal: #{document.fetch('goal')}", '', 'Done when:', *bullets('done_when'), '', scope_line,
                 '', 'Steps:', *steps]
        LIST_FIELDS.each { |field| lines.push('', "#{field.tr('_', ' ').capitalize}:", *bullets(field)) }
        lines.join("\n")
      end

      private

      def scope_line = "Scope: paths #{paths.join(', ')}; checks #{checks.empty? ? '(none)' : checks.join(', ')}"

      def bullets(field)
        items = document.fetch(field)
        items.empty? ? ['- (none)'] : items.map { |item| "- #{item}" }
      end
    end
  end
end

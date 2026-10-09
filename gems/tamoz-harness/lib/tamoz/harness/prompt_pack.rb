# frozen_string_literal: true

module Tamoz
  module Harness
    # The shipped system-prompt sections and harness tool definitions, loaded from files.
    module PromptPack
      DIRECTORY = File.expand_path('../../../prompts', __dir__)
      SECTIONS = [%w[identity 100], %w[operating 200], %w[tools 300], %w[editing 400], %w[finish 500]].freeze
      # A subagent is read-only and answers one brief: plan, editing and finish rules stay out of its header.
      SUBAGENT_SECTIONS = [%w[identity 100], %w[tools 300]].freeze
      SURFACES = {
        cli: { file: 'surface_cli', shared: SECTIONS, without: [] },
        chat: { file: 'surface_chat', shared: SECTIONS, without: [] },
        subagent: { file: 'surface_subagent', shared: SUBAGENT_SECTIONS, without: %w[update_plan] }
      }.freeze
      DIGEST_DOMAIN = "tamoz.harness.prompt.v1\n"

      module_function

      def fetch(name)
        (@texts ||= {})[name] ||= File.read(File.join(DIRECTORY, "#{name}.md"), encoding: Encoding::UTF_8).strip.freeze
      end

      def digests
        Dir.children(DIRECTORY).sort.to_h do |file|
          [file,
           Tamoz::Core.digest(DIGEST_DOMAIN,
                              { 'file' => file,
                                'bytes' => File.read(File.join(DIRECTORY, file), encoding: Encoding::UTF_8) })]
        end
      end

      def sections(surface:)
        entry = surface_entry(surface)
        entry.fetch(:shared).map { |name, order| section(name, order, fetch(name)) } +
          [section('surface', 600, fetch(entry.fetch(:file)))]
      end

      def tools
        @tools ||= JSON.parse(File.read(File.join(DIRECTORY, 'harness_tools.json'),
                                        encoding: Encoding::UTF_8)).map do |tool|
          ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                        parameters: tool.fetch('parameters'))
        end.freeze
      end

      def tool_names = tools.map(&:name)

      # The harness tools a surface is offered; a subagent has no plan to write.
      def harness_tools(surface:)
        without = surface_entry(surface).fetch(:without)
        tools.reject { |tool| without.include?(tool.name) }
      end

      # Offered only when the operator enabled subagents; `roles` are the SubagentRoles::Role values it may name.
      def delegate_tool(roles:)
        tool = JSON.parse(File.read(File.join(DIRECTORY, 'delegate.json'), encoding: Encoding::UTF_8))
        ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                      parameters: with_roles(tool.fetch('parameters'), roles))
      end

      def report_labels = (@report_labels ||= data('report_labels.json'))

      def attachment_text = (@attachment_text ||= data('attachment_text.json'))

      def data(file)
        Tamoz::Core.deep_freeze(JSON.parse(File.read(File.join(DIRECTORY, file), encoding: Encoding::UTF_8)))
      end

      # Offered only when the operator enabled memory.
      def memory_tools
        @memory_tools ||= JSON.parse(File.read(File.join(DIRECTORY, 'memory_tools.json'), encoding: Encoding::UTF_8))
                              .map do |tool|
          ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                        parameters: tool.fetch('parameters'))
        end.freeze
      end

      # Offered only when the turn has probes to cite.
      def report_tool
        @report_tool ||= JSON.parse(File.read(File.join(DIRECTORY, 'report_findings.json'), encoding: Encoding::UTF_8))
                             .then do |tool|
          ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                        parameters: tool.fetch('parameters'))
        end
      end

      def surface_entry(surface) = SURFACES.fetch(surface) { raise Error, "unknown surface #{surface.inspect}" }

      def section(name, order, text) = ContextEngine::Section.new(name:, order: Integer(order), text:)

      # :reek:TooManyStatements -- two schema fields filled from the same roles
      def with_roles(parameters, roles)
        properties = parameters.fetch('properties')
        summaries = roles.map { |role| "#{role.name}: #{role.summary}" }.join(' ')
        offered = { 'enum' => roles.map(&:name), 'description' => summaries }
        briefs = properties.fetch('briefs').merge('maxItems' => SubagentRoles.shipped.max_fanout)
        role = properties.fetch('role').merge(offered)
        parameters.merge('properties' => properties.merge('role' => role, 'briefs' => briefs))
      end
      private_class_method :surface_entry, :section, :with_roles, :data
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Harness
    # The shipped system-prompt sections and harness tool definitions, loaded from files.
    module PromptPack
      DIRECTORY = File.expand_path('../../../prompts', __dir__)
      SECTIONS = [%w[identity 100], %w[operating 200], %w[tools 300], %w[editing 400], %w[finish 500]].freeze
      SURFACES = { cli: 'surface_cli', chat: 'surface_chat' }.freeze
      DIGEST_DOMAIN = "tamoz.harness.prompt.v1\n"

      module_function

      def fetch(name)
        (@texts ||= {})[name] ||= File.read(File.join(DIRECTORY, "#{name}.md"), encoding: Encoding::UTF_8).strip.freeze
      end

      def digests
        Dir.children(DIRECTORY).sort.to_h do |file|
          [file,
           Tamoz::Core.digest(DIGEST_DOMAIN, { 'file' => file, 'bytes' => File.read(File.join(DIRECTORY, file)) })]
        end
      end

      def sections(surface:)
        surface_name = SURFACES.fetch(surface) { raise Error, "unknown surface #{surface.inspect}" }
        SECTIONS.map { |name, order| ContextEngine::Section.new(name:, order: Integer(order), text: fetch(name)) } +
          [ContextEngine::Section.new(name: 'surface', order: 600, text: fetch(surface_name))]
      end

      def tools
        @tools ||= JSON.parse(File.read(File.join(DIRECTORY, 'harness_tools.json'),
                                        encoding: Encoding::UTF_8)).map do |tool|
          ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                        parameters: tool.fetch('parameters'))
        end.freeze
      end

      def tool_names = tools.map(&:name)
    end
  end
end

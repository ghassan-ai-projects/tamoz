# frozen_string_literal: true

module Tamoz
  module Harness
    # The deep-research part of the prompt pack: the lead's and a child's tools, the web tools and the capabilities
    # that back them, the lead's loop budget, and the words that accept or stop a plan.
    module ResearchPack
      module_function

      # :lead (plan, wave, report) or :child (report_sources).
      def tools(side) = document.fetch(side.to_s).map { |tool| schema(tool) }

      # {web tool name => the websearch capability that backs it}.
      def web_backings = document.fetch('web').to_h { |tool| [tool.fetch('name'), tool.fetch('backing')] }

      def web_tools(names)
        offered = document.fetch('web').select { |tool| names.include?(tool.fetch('name')) }
        offered.map { |tool| schema(tool) }
      end

      # An ordinary turn's web tools: web_search, and read_url for a page the user or a search named.
      def chat_web
        document.fetch('web').select { |tool| tool.fetch('name') == 'web_search' } + document.fetch('chat_web')
      end

      def chat_web_backings = chat_web.to_h { |tool| [tool.fetch('name'), tool.fetch('backing')] }

      def chat_web_tools(names)
        chat_web.select { |tool| names.include?(tool.fetch('name')) }.map { |tool| schema(tool) }
      end

      # A lead's waves may run many children one after another.
      def loop_policy = @loop_policy ||= LoopPolicy.from_h(read('research_lead.json').fetch('loop_policy'))

      # {'go' => [...], 'stop' => [...]}.
      def replies = @replies ||= read('research_replies.json')

      def document = @document ||= read('research_tools.json')

      def schema(tool)
        ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                      parameters: tool.fetch('parameters'))
      end

      def read(file)
        Tamoz::Core.deep_freeze(JSON.parse(File.read(File.join(PromptPack::DIRECTORY, file), encoding: Encoding::UTF_8)))
      end
      private_class_method :document, :schema, :read, :chat_web
    end
  end
end

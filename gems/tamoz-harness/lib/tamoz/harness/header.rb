# frozen_string_literal: true

module Tamoz
  module Harness
    # The frozen request header of a work turn: prompt pack, persona and preferences, and the tool schemas.
    module Header
      module_function

      def build(tools:, model:, surface:, persona: nil, preferences: {})
        ContextEngine::RequestHeader.build(
          sections: PromptPack.sections(surface:) + Persona.sections(persona:, preferences:),
          tools: tools + PromptPack.tools,
          model:
        )
      end

      def runtime_snapshot(root:, date:, budgets:, branch: nil)
        lines = ["Workspace root: #{root}", "Date: #{date}"]
        lines << "Git branch: #{branch}" if branch
        lines << "Budgets: #{budgets.map { |key, value| "#{key} #{value}" }.join(', ')}"
        lines.join("\n")
      end
    end
  end
end

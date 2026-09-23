# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Prompt text shipped as files with the gem, loaded by name and digest-pinned.
    module Prompts
      DIRECTORY = File.expand_path('../../../prompts', __dir__)

      module_function

      def fetch(name)
        (@cache ||= {})[name] ||= File.read(File.join(DIRECTORY, "#{name}.md"), encoding: Encoding::UTF_8).strip.freeze
      end

      def digest(name)
        Tamoz::Core.digest("tamoz.context.prompt.v1\n", { 'name' => name, 'text' => fetch(name) })
      end
    end
  end
end

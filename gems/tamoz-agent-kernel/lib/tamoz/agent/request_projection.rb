# frozen_string_literal: true

module Tamoz
  module Agent
    # The one translation of tool-call structure into approval request
    # material (argv + targets). Both pipelines — the durable session gate
    # and the one-shot runtime — must present the SAME question for the same
    # call, or grants and decision digests diverge between them.
    module RequestProjection
      TOOLS_WITH_TARGETS = %w[read_file list_directory search_text apply_patch create_file].freeze

      module_function

      def argv(tool, arguments)
        case tool
        when 'run_check' then [arguments['name']].compact
        when 'git' then Array(arguments['argv'])
        when 'apply_patch'
          [arguments['path'], arguments['before'], arguments['after']].compact
        when 'create_file' then [arguments['path'], arguments['content']].compact
        else []
        end
      end

      def targets(tool, arguments)
        path = arguments['path']
        return [] unless TOOLS_WITH_TARGETS.include?(tool) && path

        [path]
      end
    end
  end
end

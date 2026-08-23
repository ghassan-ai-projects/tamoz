# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Tools
    # P15-W (docs/P18_CAPABILITY_HOST_PLAN.md §9) — the per-source dispatcher
    # for the two built-in sources the Toolbox owns: `local` (read/action
    # tools) and `skill:<catalog>` (`load_skill`, `read_skill_resource`).
    #
    # The dispatcher is the P18 interface, nothing more:
    #
    #   validate(descriptor, arguments)            -> typed D-7 result
    #   execute(descriptor, arguments, context:)   -> the tool's own result
    #
    # plus the effect/preview hooks the step gate needs. Every method forwards
    # to the Toolbox by the descriptor's model-visible id, so the toolbox stays
    # the single implementation and the host gains no authority of its own: a
    # descriptor the toolbox does not expose cannot be dispatched, because
    # `Toolbox#validate` refuses an unknown name.
    #
    # The dispatcher is deliberately stateless apart from its toolbox: the
    # registry is sealed at session construction and a dispatcher must never
    # be able to widen what its source already published.
    class LocalDispatcher
      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      attr_reader :toolbox

      def validate(descriptor, arguments)
        toolbox.validate(descriptor.id, arguments)
      end

      # `context:` is part of the uniform protocol (MCP needs it); local tools
      # execute inside the caller's effect journal and take no context.
      def execute(descriptor, arguments, context: nil)
        toolbox.execute(descriptor.id, arguments)
      end

      def preview(descriptor, arguments)
        toolbox.preview(descriptor.id, arguments)
      end

      def effect_intent(descriptor, arguments)
        toolbox.effect_intent(descriptor.id, arguments)
      end

      def maximum_effect_output_bytes(descriptor)
        toolbox.maximum_effect_output_bytes(descriptor.id)
      end

      # The safety class of one dispatch. `run_check` is argument-dependent:
      # the operator declares each configured check's safety, and the default
      # is `:unsafe`, so an ambiguous crash never silently repeats a command.
      def safety(descriptor, arguments)
        case descriptor.id
        when "apply_patch", "create_file" then :reconcilable
        when "run_check" then toolbox.check_safety(arguments.fetch("name"))
        else :read_only
        end
      end
    end
  end
end

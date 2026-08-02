# frozen_string_literal: true

module Tamoz
  module Core
    # P16: the D-7 tool-error taxonomy, homed in tamoz-core so the dependency graph
    # stays tamoz-core <- tamoz-tools <- tamoz-agent. `Tamoz::Tools::ToolError` and
    # `Tamoz::Agent::ToolError` are constant aliases of these classes; the alias
    # never changes `.name`, so every serializer maps the core name back to the
    # agent spelling via `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`.

    # A tool refused to act.
    #
    # The base class is terminal by construction: a raise site that has not been
    # classified propagates and ends the session. Only `ToolArgumentError` is ever
    # converted into evidence, and only through `repairable?` — never by matching on
    # message text.
    #
    # Every `ToolError` message is built from Tamoz literals plus Tamoz-computed
    # metadata (digests, counts, limits) or a workspace-relative path or argument name
    # that the same operator already sees in the approval preview and in the durable
    # `review` record, so the class opts in to message disclosure.
    class ToolError < Tamoz::Error
      include Tamoz::DisclosableMessage

      def repairable? = false
    end

    # Sandbox containment and approval integrity: root escape, absolute paths,
    # symlinked components, null bytes, and a workspace that no longer matches the
    # approved before-state. Always terminal — a security rejection must never become
    # a retryable value the planner can iterate against.
    class ToolPolicyError < ToolError; end

    # A failure fully attributable to the arguments the planner chose: text that does
    # not match, an ambiguous match, a stale digest, a missing target, or an argument
    # that fails shape/encoding validation. Nothing was mutated, so the correct
    # response is to re-read the workspace and plan different arguments.
    class ToolArgumentError < ToolError
      def repairable? = true
    end
  end
end

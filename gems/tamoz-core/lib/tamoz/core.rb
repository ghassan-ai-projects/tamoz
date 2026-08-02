# frozen_string_literal: true

require "zeitwerk"
require_relative "core/version"

module Tamoz
  module Core
    ROOT = File.expand_path("../../..", __dir__).freeze

    # P16: pre-P9 sessions carry no skill catalog. "none" is the epoch of a session
    # that had no skills, which is exactly what a skill-free P9 session records
    # too, so an old session and a new skill-free session resume identically
    # (invariant 41). Homed here so the moved toolbox's empty-snapshot
    # `skill_epoch` resolves without any agent constant.
    LEGACY_SKILL_EPOCH = "none"

    # P16: the D-7 taxonomy classes moved into tamoz-core, but every durable and
    # model-visible serialization of them keeps the public `Tamoz::Agent::Tool*`
    # spellings. This is the single stable mapping applied at the three
    # serialization sites (effect journal, session record, model-visible failure
    # payload); the repair-loop dedup keys hash kind/tool/reason/arguments and
    # contain no class name, so the mapping cannot churn dedup.
    TOOL_ERROR_CLASS_NAMES = {
      "Tamoz::Core::ToolError" => "Tamoz::Agent::ToolError",
      "Tamoz::Core::ToolArgumentError" => "Tamoz::Agent::ToolArgumentError",
      "Tamoz::Core::ToolPolicyError" => "Tamoz::Agent::ToolPolicyError"
    }.freeze

    loader = Zeitwerk::Loader.new
    loader.tag = "tamoz-core"
    loader.push_dir(File.expand_path("..", __dir__))
    loader.ignore(__FILE__)
    loader.ignore(File.expand_path("core/version.rb", __dir__))
    loader.setup
    loader.eager_load
    @loader = loader

    module_function

    # Serializes a class name through the tool-error mapping. Anything outside the
    # D-7 family passes through unchanged, so unrelated classes always emit their
    # true `.name` (never a forced or raw-core spelling).
    def serialized_tool_error_name(value)
      TOOL_ERROR_CLASS_NAMES.fetch(String(value), String(value))
    end

    # Pure canonical sorter (the deliberation canonical, homed in core so the
    # skills digests and the session-record digests share one implementation):
    # keys sorted, stringified, recursed; the input is never mutated.
    def canonical(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, entry), normalized|
          normalized[String(key)] = canonical(entry)
        end.sort.to_h
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    # Deep freezer for JSON-shaped values (the plan/session-records freezer, homed
    # in core so the skills compiler and the durable records share one
    # implementation). Scalars are returned as-is, containers are rebuilt with
    # frozen keys/values, and anything that cannot cross a durable boundary raises.
    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, entry| [String(key).dup.freeze, deep_freeze(entry)] }.freeze
      when Array
        value.map { |entry| deep_freeze(entry) }.freeze
      when String
        value.dup.freeze
      when NilClass, TrueClass, FalseClass, Numeric
        value
      else
        raise Tamoz::Error, "unsupported plan argument #{value.class}"
      end
    end
  end
end

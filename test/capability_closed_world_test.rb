# frozen_string_literal: true

require_relative "test_helper"

# P18 (H3/C4/DC-6 + H6/C7) — closed-world composition and error identity.
#
# - H3: all four built-in source dispatchers run through ONE protocol with
#   zero source-typed branches in the host; a fifth synthetic source FAILS at
#   construction; multiple descriptors within an existing source work.
# - H6: a typed error (repairable or policy) from any source passes through
#   the host with class + message bytes identical — the host wraps only
#   non-ToolError exceptions.
#
# The dispatcher interface (per-source): validate(descriptor, arguments) and
# execute(descriptor, arguments, context:). The protocol below is the single
# host dispatch body — no `case source.kind` anywhere.
class CapabilityClosedWorldTest < Minitest::Test
  Capability = Tamoz::Core::Capability

  # A minimal typed error the source layers use (repairable class family).
  class SourceToolError < StandardError
    attr_reader :category, :retryable

    def initialize(category:, retryable_flag:, message:)
      @category = category
      @retryable = retryable_flag
      super(message)
    end
  end

  def descriptor(id:, kind:, source_id:, effect_class: :read_only, **overrides)
    Capability::Descriptor.new(
      id:, kind:, source_id:, trust: :local, effect_class:,
      protocol_profile: {"transport" => "in_process"},
      input_schema: {"type" => "object"},
      output_schema: {"type" => "object"}, **overrides
    )
  end

  # The four built-in sources with their per-source dispatchers. Each
  # dispatcher implements validate/execute with NO host-visible typing: the
  # protocol calls them uniformly.
  def built_in_sources
    local = Capability::Source.new(
      source_id: "local",
      descriptors: [descriptor(id: "read_file", kind: :tool, source_id: "local")]
    )
    skill = Capability::Source.new(
      source_id: "skill:dev/helper",
      descriptors: [
        descriptor(id: "load_skill", kind: :skill, source_id: "skill:dev/helper"),
        descriptor(id: "read_skill_resource", kind: :skill, source_id: "skill:dev/helper")
      ]
    )
    mcp = Capability::Source.new(
      source_id: "mcp:server-a",
      descriptors: [descriptor(id: "mcp:server-a/tool_x", kind: :mcp_tool, source_id: "mcp:server-a")]
    )
    web = Capability::Source.new(
      source_id: "websearch",
      descriptors: [descriptor(id: "websearch:search", kind: :websearch, source_id: "websearch")]
    )
    [local, skill, mcp, web]
  end

  # The dispatcher map: source_id => {validate:, execute:}. The HOST protocol
  # (dispatch below) has ZERO branches on the source kind.
  def dispatchers
    @dispatchers ||= {
      "local" => {
        validate: ->(_descriptor, arguments) { arguments.key?("path") ? :ok : raise(SourceToolError.new(category: "tool_argument", retryable_flag: false, message: "path is required")) },
        execute: ->(_descriptor, arguments, _context) { {"read" => arguments.fetch("path")} }
      },
      "skill:dev/helper" => {
        validate: ->(_descriptor, _arguments) { :ok },
        execute: ->(descriptor, _arguments, _context) { {"skill" => descriptor.id} }
      },
      "mcp:server-a" => {
        validate: ->(_descriptor, _arguments) { :ok },
        execute: ->(descriptor, _arguments, _context) { {"mcp" => descriptor.id} }
      },
      "websearch" => {
        validate: ->(_descriptor, _arguments) { :ok },
        execute: ->(descriptor, _arguments, _context) { {"websearch" => descriptor.id} }
      }
    }
  end

  # The SINGLE host dispatch protocol. Zero source-typed branches.
  def dispatch(registry, descriptor_id, arguments, context: {}, dispatcher_override: nil)
    descriptor = registry.descriptors.fetch(descriptor_id)
    source = registry.source_for(descriptor_id)
    dispatcher = (dispatcher_override || dispatchers).fetch(source.source_id)
    dispatcher.fetch(:validate).call(descriptor, arguments)
    dispatcher.fetch(:execute).call(descriptor, arguments, context)
  rescue SourceToolError => error
    # H6: a typed error passes through with class + message bytes identical.
    raise error
  rescue StandardError => error
    # The host wraps ONLY non-ToolError exceptions (invariant 17 at the
    # boundary).
    raise SourceToolError.new(category: "host_wrap", retryable_flag: false,
                              message: "host wrapped: #{error.class}: #{error.message}")
  end

  # H3: all four built-in sources dispatch through the ONE protocol; a fifth
  # synthetic source fails at construction.
  def test_four_built_ins_dispatch_through_one_protocol
    registry = Capability::Registry.build(
      sources: built_in_sources,
      admission_set: %w[read_file load_skill read_skill_resource
                        mcp:server-a/tool_x websearch:search]
    )
    # Four source kinds, one protocol, zero typed branches in `dispatch`.
    assert_equal({"read" => "a.txt"},
                 dispatch(registry, "read_file", {"path" => "a.txt"}))
    assert_equal({"skill" => "load_skill"},
                 dispatch(registry, "load_skill", {}))
    assert_equal({"skill" => "read_skill_resource"},
                 dispatch(registry, "read_skill_resource", {}))
    assert_equal({"mcp" => "mcp:server-a/tool_x"},
                 dispatch(registry, "mcp:server-a/tool_x", {}))
    assert_equal({"websearch" => "websearch:search"},
                 dispatch(registry, "websearch:search", {"q" => "ruby"}))

    # A fifth synthetic source fails at construction (closed world).
    synthetic = Capability::Source.new(
      source_id: "synthetic",
      descriptors: [descriptor(id: "evil", kind: :tool, source_id: "synthetic")]
    )
    assert_raises(Capability::DescriptorConflictError) do
      Capability::Registry.build(
        sources: built_in_sources + [synthetic],
        admission_set: %w[read_file]
      )
    end
  end

  # H6: a typed error passes through with class + message bytes identical.
  def test_typed_errors_pass_through_with_identity
    registry = Capability::Registry.build(
      sources: built_in_sources, admission_set: %w[read_file]
    )
    error = assert_raises(SourceToolError) do
      dispatch(registry, "read_file", {}) # missing path -> typed validation error
    end
    assert_equal "tool_argument", error.category
    assert_equal "path is required", error.message
    assert_equal false, error.retryable
  end

  # The host wraps only non-ToolError exceptions.
  def test_untyped_errors_are_wrapped_at_the_boundary
    registry = Capability::Registry.build(
      sources: built_in_sources, admission_set: %w[read_file]
    )
    # A local execute that raises a plain RuntimeError (untyped).
    local_dispatchers = dispatchers.merge(
      "local" => {
        validate: ->(_d, _a) { :ok },
        execute: ->(_d, _a, _c) { raise "boom" }
      }
    )
    error = assert_raises(SourceToolError) do
      dispatch(registry, "read_file", {"path" => "x"}, dispatcher_override: local_dispatchers)
    end
    assert_equal "host_wrap", error.category
    assert_includes error.message, "boom"
  end
end

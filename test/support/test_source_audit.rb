# frozen_string_literal: true

require 'prism'

module TestSourceAudit
  ASSERTIONS = %i[assert refute assert_equal refute_equal].freeze
  ENUMERATORS = %i[any? all? none? one? find select map].freeze
  PLAN_VOCABULARY = [
    /§/,
    /\bP\d+\b/,
    /\bDR-?\d/,
    /\bDC-\d/,
    /\bD-\d/,
    /\bA-\d/,
    /\bT\d+(?:\.\d+)?\b/,
    /(?<![\w-])F\d\b/,
    /\bQ\d/,
    /\b[Ss]lice\s+[0-9A-Z]/,
    /[Pp]hase\s*\d/,
    /\bwave\s+[A-Z]\b/
  ].freeze

  module_function

  def ignored_predicates(source)
    result = Prism.parse(source)
    raise ArgumentError, result.errors.map(&:message).join(', ') unless result.success?

    findings = []
    visit(result.value) do |node|
      next unless ignored_predicate?(node)

      findings << node.location.start_line
    end
    findings
  end

  def plan_vocabulary(source)
    result = Prism.parse(source)
    raise ArgumentError, result.errors.map(&:message).join(', ') unless result.success?

    result.comments
          .select { |comment| PLAN_VOCABULARY.any? { |pattern| comment.slice.match?(pattern) } }
          .map { |comment| comment.location.start_line }
  end

  def ignored_predicate?(node)
    return false unless node.is_a?(Prism::CallNode) && ASSERTIONS.include?(node.name) && node.block

    node.arguments&.arguments.to_a.any? do |argument|
      argument.is_a?(Prism::CallNode) && ENUMERATORS.include?(argument.name) && !argument.block
    end
  end

  def visit(node, &block)
    yield node
    node.compact_child_nodes.each { |child| visit(child, &block) }
  end
end

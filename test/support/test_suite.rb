# frozen_string_literal: true

require 'prism'

module TestSuite
  ROOT = File.expand_path('../..', __dir__).freeze
  TEST_PATTERNS = %w[test/**/*_test.rb gems/*/test/**/*_test.rb agenteval/test/**/*_test.rb].freeze
  SOURCE_PATTERNS = %w[Rakefile bin/* script/* script/**/*.rb scripts/**/*.rb apps/**/*.rb
                       gems/**/*.rb gems/**/exe/* test/**/*.rb agenteval/**/*.rb].freeze

  module_function

  def files(root: ROOT)
    discover(TEST_PATTERNS, root:)
  end

  def sources(root: ROOT)
    discover(SOURCE_PATTERNS, root:)
  end

  def coverage_environment
    { 'RUN_COVERAGE' => '1', 'SEED' => '1', 'TEST' => nil, 'TESTOPTS' => nil }
  end

  def validate_runnable_methods!
    hidden = Minitest::Runnable.runnables.flat_map do |suite|
      methods = suite.private_instance_methods + suite.protected_instance_methods
      methods.grep(/^test_/).map { |name| "#{suite}##{name}" }
    end
    raise ArgumentError, "non-public test methods: #{hidden.sort.join(', ')}" unless hidden.empty?
  end

  def discover(patterns, root:)
    Dir.glob(patterns, base: root).select { |path| File.file?(File.join(root, path)) }.uniq.sort
  end

  def lanes(slow:, serial:, autonomy:, manual:, root: ROOT)
    all = files(root:)
    explicit = { slow:, serial:, autonomy:, manual: }
    entries = explicit.values.flatten
    missing = entries - all
    duplicates = entries.tally.select { |_, count| count > 1 }.keys
    raise ArgumentError, "missing lane files: #{missing.join(', ')}" unless missing.empty?
    raise ArgumentError, "duplicate lane files: #{duplicates.join(', ')}" unless duplicates.empty?

    { fast: all - entries, **explicit }.transform_values { |paths| paths.sort.freeze }.freeze
  end

  def validate_identities!(paths, root: ROOT)
    identities = { classes: {}, methods: {} }
    paths.each do |path|
      result = Prism.parse_file(File.join(root, path))
      raise ArgumentError, "invalid Ruby test source: #{path}" unless result.success?

      visit(result.value, path:, identities:)
    end
  end

  def visit(node, path:, identities:, namespace: [], owner: nil)
    case node
    when Prism::ModuleNode, Prism::ClassNode
      visit_scope(node, path:, identities:, namespace:)
    when Prism::DefNode
      record_test_method!(identities, node.name.to_s, owner, path) unless node.receiver
    else
      record_test_method!(identities, generated_name(node), owner, path)
      node.compact_child_nodes.each { |child| visit(child, path:, identities:, namespace:, owner:) }
    end
  end

  def visit_scope(node, path:, identities:, namespace:)
    name = node.constant_path.slice
    scope = name.start_with?('::') ? [name.delete_prefix('::')] : namespace + [name]
    owner = nil
    if test_class?(node, name)
      owner = scope.join('::')
      record_identity!(identities.fetch(:classes), owner, path, 'test class')
    end
    visit(node.body, path:, identities:, namespace: scope, owner:) if node.body
  end

  def test_class?(node, name)
    node.is_a?(Prism::ClassNode) && (name.end_with?('Test') || node.superclass&.slice.to_s.end_with?('Test'))
  end

  def generated_name(node)
    return unless node.is_a?(Prism::CallNode) && node.name == :define_method && !node.receiver

    name = node.arguments&.arguments&.first
    name.unescaped if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
  end

  def record_test_method!(identities, name, owner, path)
    return unless owner && name&.start_with?('test_')

    record_identity!(identities.fetch(:methods), "#{owner}##{name}", path, 'test method')
  end

  def record_identity!(seen, identity, path, kind)
    previous = seen[identity]
    raise ArgumentError, "duplicate #{kind} #{identity}: #{previous}, #{path}" if previous

    seen[identity] = path
  end
end

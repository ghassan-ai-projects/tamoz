# frozen_string_literal: true

module Agenteval
  # A generated multi-file project. Difficulty is a generation parameter — the number of
  # operations, the depth of the call chain, and the volume of distractor modules — so the
  # same task definition produces unbounded headroom rather than a fixed ceiling.
  #
  # Generated code is deliberately plain and old-syntax so it runs on whatever interpreter
  # the machine has, and reads like something a person wrote.
  class Project
    Spec = Struct.new(:package, :operations, :chain, :language, :seed, keyword_init: true)

    Operation = Struct.new(:name, :factor, :offset, :probe, :expected, keyword_init: true)

    def self.generate(seeded, language:, difficulty: 2)
      package = seeded.identifier(:package)
      count = 3 + difficulty
      operations = Array.new(count) do
        factor = seeded.int(2..9)
        offset = seeded.int(1..40)
        probe = seeded.int(3..30)
        Operation.new(
          name: seeded.identifier(:function),
          factor: factor,
          offset: offset,
          probe: probe,
          expected: (probe * factor) + offset
        )
      end
      # At least two operations stay outside the pipeline chain, so a task can target an
      # operation that genuinely has no other test covering it.
      chain = seeded.sample(operations, [[2 + difficulty, count - 2].min, 2].max)
      new(Spec.new(package: package, operations: operations, chain: chain,
                   language: language, seed: seeded.seed))
    end

    attr_reader :spec

    def initialize(spec)
      @spec = spec
    end

    def package = spec.package
    def operations = spec.operations
    def chain = spec.chain
    def language = spec.language

    def files = language.emit(self)

    def test_command = language.test_command(self)

    def chain_input = 5

    def chain_expected
      chain.reduce(chain_input) { |value, op| (value * op.factor) + op.offset }
    end

    def module_name
      package.split("_").map(&:capitalize).join
    end
  end

  # A language backend: how to write the generated project, and how to run its suite.
  # Adding a language is adding one of these; nothing else in the framework changes.
  module Languages
    class Ruby
      def id = :ruby
      def label = "Ruby"
      def ext = "rb"

      def core_path(project) = "lib/#{project.package}/core.rb"
      def registry_path(project) = "lib/#{project.package}/registry.rb"
      def pipeline_path(project) = "lib/#{project.package}/pipeline.rb"
      def test_path(project) = "test/#{project.package}_test.rb"

      def test_command(project) = ["ruby", "-Ilib", "-Itest", test_path(project)]

      def emit(project)
        {
          "README.md" => readme(project),
          "lib/#{project.package}.rb" => entry(project),
          core_path(project) => core(project),
          registry_path(project) => registry(project),
          pipeline_path(project) => pipeline(project),
          test_path(project) => tests(project)
        }
      end

      def readme(project)
        <<~MD
          # #{project.package}

          A small numeric pipeline library.

          - `#{core_path(project)}` — the individual operations
          - `#{registry_path(project)}` — resolves an operation by name
          - `#{pipeline_path(project)}` — applies a sequence of operations in order

          Run the suite with `#{test_command(project).join(" ")}`.
        MD
      end

      def entry(project)
        <<~RUBY
          # frozen_string_literal: true

          require "#{project.package}/core"
          require "#{project.package}/registry"
          require "#{project.package}/pipeline"

          module #{project.module_name}
            UnknownOperation = Class.new(StandardError)
          end
        RUBY
      end

      def core(project)
        body = project.operations.map do |op|
          <<~RUBY.chomp
                def self.#{op.name}(value)
                  (value * #{op.factor}) + #{op.offset}
                end
          RUBY
        end.join("\n\n")

        <<~RUBY
          # frozen_string_literal: true

          module #{project.module_name}
            # Each operation maps one integer to another. They are pure and independent.
            module Core
          #{body}
            end
          end
        RUBY
      end

      def registry(project)
        entries = project.operations.map do |op|
          "        \"#{op.name}\" => Core.method(:#{op.name})"
        end.join(",\n")

        <<~RUBY
          # frozen_string_literal: true

          module #{project.module_name}
            module Registry
              OPERATIONS = {
          #{entries}
              }.freeze

              def self.fetch(name)
                OPERATIONS.fetch(name) { raise UnknownOperation, "unknown operation: " + name.to_s }
              end

              def self.names
                OPERATIONS.keys
              end
            end
          end
        RUBY
      end

      def pipeline(project)
        <<~RUBY
          # frozen_string_literal: true

          module #{project.module_name}
            module Pipeline
              # Applies each named operation in order, feeding one result into the next.
              def self.apply(value, names)
                names.reduce(value) do |carried, name|
                  Registry.fetch(name).call(carried)
                end
              end
            end
          end
        RUBY
      end

      def tests(project)
        cases = project.operations.map do |op|
          <<~RUBY.chomp
              def test_#{op.name}
                assert_equal #{op.expected}, #{project.module_name}::Core.#{op.name}(#{op.probe})
              end
          RUBY
        end.join("\n\n")

        names = project.chain.map { |op| "\"#{op.name}\"" }.join(", ")

        <<~RUBY
          # frozen_string_literal: true

          require "minitest/autorun"
          require "#{project.package}"

          class #{project.module_name}Test < Minitest::Test
          #{cases}

            def test_pipeline_applies_every_operation_in_order
              assert_equal(
                #{project.chain_expected},
                #{project.module_name}::Pipeline.apply(#{project.chain_input}, [#{names}])
              )
            end

            def test_unknown_operation_is_rejected
              assert_raises(#{project.module_name}::UnknownOperation) do
                #{project.module_name}::Registry.fetch("no_such_operation")
              end
            end
          end
        RUBY
      end
    end

    class Python
      def id = :python
      def label = "Python"
      def ext = "py"

      def core_path(project) = "src/#{project.package}/core.py"
      def registry_path(project) = "src/#{project.package}/registry.py"
      def pipeline_path(project) = "src/#{project.package}/pipeline.py"
      def test_path(project) = "test/test_#{project.package}.py"

      def test_command(project) = ["python3", test_path(project)]

      def emit(project)
        {
          "README.md" => readme(project),
          "src/#{project.package}/__init__.py" => entry(project),
          core_path(project) => core(project),
          registry_path(project) => registry(project),
          pipeline_path(project) => pipeline(project),
          test_path(project) => tests(project)
        }
      end

      def readme(project)
        <<~MD
          # #{project.package}

          A small numeric pipeline library.

          - `#{core_path(project)}` — the individual operations
          - `#{registry_path(project)}` — resolves an operation by name
          - `#{pipeline_path(project)}` — applies a sequence of operations in order

          Run the suite with `#{test_command(project).join(" ")}`.
        MD
      end

      def entry(_project)
        <<~PY
          class UnknownOperation(Exception):
              pass
        PY
      end

      def core(project)
        body = project.operations.map do |op|
          <<~PY.chomp
            def #{op.name}(value):
                return (value * #{op.factor}) + #{op.offset}
          PY
        end.join("\n\n\n")

        "\"\"\"Each operation maps one integer to another. They are pure and independent.\"\"\"\n\n\n#{body}\n"
      end

      def registry(project)
        entries = project.operations.map { |op| "    \"#{op.name}\": core.#{op.name}," }.join("\n")

        <<~PY
          from . import core
          from . import UnknownOperation

          OPERATIONS = {
          #{entries}
          }


          def fetch(name):
              if name not in OPERATIONS:
                  raise UnknownOperation("unknown operation: " + str(name))
              return OPERATIONS[name]


          def names():
              return list(OPERATIONS)
        PY
      end

      def pipeline(project)
        <<~PY
          from . import registry


          def apply(value, names):
              """Applies each named operation in order, feeding one result into the next."""
              carried = value
              for name in names:
                  carried = registry.fetch(name)(carried)
              return carried
        PY
      end

      def tests(project)
        # Built without a squiggly heredoc on purpose: `<<~` strips the common indentation,
        # which is exactly the thing Python cares about.
        cases = project.operations.map do |op|
          "    def test_#{op.name}(self):\n" \
            "        self.assertEqual(#{op.expected}, core.#{op.name}(#{op.probe}))\n"
        end.join("\n")

        names = project.chain.map { |op| "\"#{op.name}\"" }.join(", ")

        header = <<~PY
          import os
          import sys
          import unittest

          sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

          from #{project.package} import core, pipeline, registry, UnknownOperation


          class #{project.module_name}Test(unittest.TestCase):
        PY

        footer =
          "\n    def test_pipeline_applies_every_operation_in_order(self):\n" \
          "        self.assertEqual(\n" \
          "            #{project.chain_expected},\n" \
          "            pipeline.apply(#{project.chain_input}, [#{names}]),\n" \
          "        )\n" \
          "\n    def test_unknown_operation_is_rejected(self):\n" \
          "        with self.assertRaises(UnknownOperation):\n" \
          "            registry.fetch(\"no_such_operation\")\n" \
          "\n\nif __name__ == \"__main__\":\n    unittest.main()\n"

        header + cases + footer
      end
    end

    ALL = {ruby: Ruby.new, python: Python.new}.freeze

    def self.fetch(id) = ALL.fetch(id.to_sym)
  end
end

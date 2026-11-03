# frozen_string_literal: true

require 'strscan'

module Tamoz
  module Agent
    # A playbook rule's `when`, in the part of CEL a draft may use.
    class FeatureCondition
      class Invalid < StandardError
      end

      class Mismatch < StandardError
      end
      private_constant :Mismatch

      MAX_BYTES = 1024
      MAX_DEPTH = 32
      NUMBER = /\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/
      TOKEN = %r{#{NUMBER}|features\.[A-Za-z_][A-Za-z0-9_]*|true\b|false\b|&&|\|\||[<>=!]=|[<>!()+\-*/]}
      COMPARISONS = %w[< <= > >= == !=].freeze

      attr_reader :features

      def self.parse(text, allowed:)
        raise Invalid, 'the condition is not a string' unless text.is_a?(String)
        raise Invalid, "the condition is over #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES

        new(text, allowed)
      end

      def initialize(text, allowed)
        @tokens = tokenize(text)
        @position = 0
        @depth = 0
        @features = []
        @tree = disjunction
        raise Invalid, "unexpected #{@tokens[@position]}" if @position < @tokens.length

        raise Invalid, 'the condition reads no feature' if @features.empty?

        unknown = @features - allowed
        raise Invalid, "features.#{unknown.first} is not an allowed feature" unless unknown.empty?

        @features.freeze
        freeze
      end

      def holds?(values) = failure(values).nil?

      def failure(values)
        absent = @features.reject { |name| values.key?(name) }
        return "#{absent.map { |name| "features.#{name}" }.join(', ')} absent" unless absent.empty?

        result = evaluate(@tree, values)
        result == true ? nil : "it evaluates to #{result}"
      rescue Mismatch
        'it mixes a number and a boolean'
      end

      private

      def tokenize(text)
        scanner = StringScanner.new(text)
        tokens = []
        until scanner.skip(/\s*/) && scanner.eos?
          token = scanner.scan(TOKEN) or raise Invalid, unexpected(scanner.rest)
          tokens << token
        end
        raise Invalid, 'the condition is empty' if tokens.empty?

        tokens
      end

      def unexpected(rest)
        name = rest[/\A[A-Za-z_][A-Za-z0-9_]*/]
        return "unexpected #{rest[0, 16].inspect}" unless name

        "unexpected #{name}: write a feature as features.#{name}"
      end

      def disjunction = binary_chain(%w[||]) { conjunction }
      def conjunction = binary_chain(%w[&&]) { comparison }
      def sum = binary_chain(%w[+ -]) { product }
      def product = binary_chain(%w[* /]) { unary }

      def binary_chain(operators)
        tree = yield
        tree = [:binary, take, tree, yield] while operators.include?(peek)
        tree
      end

      def comparison
        tree = sum
        COMPARISONS.include?(peek) ? [:binary, take, tree, sum] : tree
      end

      def unary
        case peek
        when '!' then take && nested { [:not, unary] }
        when '-' then take && nested { [:negate, unary] }
        else operand
        end
      end

      def operand
        token = take or raise Invalid, 'the condition ends early'
        case token
        when '(' then nested { parenthesized }
        when 'true', 'false' then [:value, token == 'true']
        when /\Afeatures\./ then feature(token.delete_prefix('features.'))
        when NUMBER then [:value, number_literal(token)]
        else raise Invalid, "unexpected #{token}"
        end
      end

      # CEL never mixes an int and a double, and the features are doubles.
      def number_literal(token)
        raise Invalid, "write #{token} as a double, such as #{token}.0" unless token.include?('.')

        value = Float(token)
        raise Invalid, "#{token} is out of range" unless value.finite?

        value
      end

      def nested
        @depth += 1
        raise Invalid, "the condition nests deeper than #{MAX_DEPTH}" if @depth > MAX_DEPTH

        result = yield
        @depth -= 1
        result
      end

      def parenthesized
        tree = disjunction
        raise Invalid, 'a parenthesis is not closed' unless take == ')'

        tree
      end

      def feature(name)
        @features << name unless @features.include?(name)
        [:feature, name]
      end

      def peek = @tokens[@position]

      def take
        token = @tokens[@position]
        @position += 1
        token
      end

      def evaluate(tree, values)
        case tree.first
        when :value then tree.last
        when :feature then feature_value(values.fetch(tree.last))
        when :not then !boolean(evaluate(tree.last, values))
        when :negate then -number(evaluate(tree.last, values))
        else operate(tree[1], evaluate(tree[2], values), evaluate(tree[3], values))
        end
      end

      def feature_value(value)
        [true, false].include?(value) ? value : number(value).to_f
      end

      def operate(operator, left, right)
        case operator
        when '&&' then boolean(left) && boolean(right)
        when '||' then boolean(left) || boolean(right)
        when '==', '!=' then equality(operator, left, right)
        else number(left).public_send(operator, number(right))
        end
      end

      def equality(operator, left, right)
        raise Mismatch unless [left, right].all?(Numeric) || [left, right].all? { |side| [true, false].include?(side) }

        (left == right) == (operator == '==')
      end

      def boolean(value)
        raise Mismatch unless [true, false].include?(value)

        value
      end

      def number(value)
        raise Mismatch unless value.is_a?(Numeric)

        value
      end
    end
  end
end

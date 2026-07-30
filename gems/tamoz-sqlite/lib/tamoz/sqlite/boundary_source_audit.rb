# frozen_string_literal: true

require "ripper"
require "set"

module Tamoz
  module SQLite
    module BoundarySourceAudit
      MAX_SOURCE_BYTES = 2 * 1024 * 1024
      TRANSACTION_METHODS = %w[read transaction].freeze
      STATEMENT_ACCESS = {
        "execute" => "write",
        "first" => "read",
        "rows" => "read",
        "scalar" => "read"
      }.freeze
      DYNAMIC_INDEX_PREFIXES = %w[
        checkpoint.commit.consume.
        checkpoint.writes.item.
      ].freeze
      DYNAMIC_EXECUTION = %w[
        class_eval eval instance_eval module_eval
      ].freeze
      FILESYSTEM_CONSTANTS = %w[
        Dir File FileUtils IO Pathname Tempfile
      ].freeze
      FILE_MUTATIONS = %w[
        binwrite chmod chown copy cp cp_r delete install link ln ln_s
        mkdir mkdir_p move mv open remove remove_dir remove_entry rename
        rm rm_f rm_r rm_rf rmdir safe_unlink symlink touch truncate unlink
        utime write
      ].freeze

      TX = Object.new.freeze
      UNKNOWN = Object.new.freeze

      MethodDefinition = Data.define(
        :name,
        :required_parameters,
        :keyword_parameters,
        :body
      )
      Call = Data.define(:name, :receiver, :positional, :keywords)

      module_function

      def audit!(registry:, paths:)
        Auditor.new(registry:, paths:).audit!
      end

      class Auditor
        def initialize(registry:, paths:)
          @registry = registry
          @paths = Array(paths).map { |path| File.expand_path(path) }.freeze
          @methods = {}
          @roots = []
          @source = {}
          @call_stack = []
          @visited_methods = Set.new
        end

        def audit!
          raise ConfigurationError, "boundary audit requires source paths" if @paths.empty?

          @paths.each { |path| parse_source(path) }
          reject_duplicate_operations!
          @roots.each { |root| inspect_root(*root) }
          unreachable = @methods.keys.to_set - @visited_methods
          unless unreachable.empty?
            raise ConfigurationError,
                  "boundary helpers are unreachable: #{unreachable.to_a.sort.join(", ")}"
          end
          compare_registry!
          deep_freeze(
            @source.keys.sort.to_h do |operation|
              statements = @source.fetch(operation)
              [
                operation,
                statements.keys.sort.to_h do |label|
                  [label, statements.fetch(label)]
                end
              ]
            end
          )
        end

        private

        def parse_source(path)
          bytes = File.binread(path, MAX_SOURCE_BYTES + 1)
          if bytes.bytesize > MAX_SOURCE_BYTES
            raise ConfigurationError, "boundary source exceeds #{MAX_SOURCE_BYTES} bytes"
          end
          source = bytes.force_encoding(Encoding::UTF_8)
          unless source.valid_encoding?
            raise ConfigurationError, "boundary source is not valid UTF-8"
          end

          syntax = Ripper.sexp(source)
          raise ConfigurationError, "boundary source has invalid Ruby syntax" unless syntax

          inspect_forbidden!(syntax)
          collect_definitions!(syntax)
          collect_roots!(syntax)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
          raise ConfigurationError, "cannot read boundary source: #{error.message}"
        end

        def collect_definitions!(node)
          return unless node.is_a?(Array)

          if node.fetch(0, nil) == :def
            definition = method_definition(node)
            return unless (
              definition.required_parameters +
              definition.keyword_parameters
            ).include?("tx")

            if @methods.key?(definition.name)
              raise ConfigurationError,
                    "duplicate boundary helper method #{definition.name.inspect}"
            end
            @methods[definition.name] = definition
          end
          node.each { |child| collect_definitions!(child) if child.is_a?(Array) }
        end

        def collect_roots!(node)
          return unless node.is_a?(Array)

          if node.fetch(0, nil) == :method_add_block
            call = parse_call(node.fetch(1))
            if transaction_call?(call)
              operation = transaction_operation(call)
              block = node.fetch(2)
              tx_name = block_parameter(block)
              unless tx_name
                raise ConfigurationError,
                      "boundary operation #{operation.inspect} requires one block parameter"
              end
              @roots << [operation, block_body(block), tx_name]
              return
            end
          elsif %i[command command_call method_add_arg].include?(
            node.fetch(0, nil)
          ) && transaction_call?(parse_call(node))
            raise ConfigurationError, "boundary operation requires a block"
          end
          node.each { |child| collect_roots!(child) if child.is_a?(Array) }
        end

        def reject_duplicate_operations!
          names = @roots.map(&:first)
          duplicate = names.tally.find { |_name, count| count > 1 }&.first
          return unless duplicate

          raise ConfigurationError,
                "boundary operation #{duplicate.inspect} is declared more than once"
        end

        def inspect_root(operation, body, tx_name)
          @source[operation] = {}
          inspect_node(body, operation, {tx_name => TX})
        end

        def inspect_node(node, operation, environment)
          return unless node.is_a?(Array)

          call = parse_call(node) if
            %i[command command_call method_add_arg].include?(node.fetch(0, nil))
          if call
            if statement_call?(call, environment)
              record_statement!(operation, call, environment)
            elsif helper_call?(call, environment)
              inspect_helper(call, operation, environment)
            end
          end

          node.each { |child| inspect_node(child, operation, environment) if child.is_a?(Array) }
        end

        def statement_call?(call, environment)
          STATEMENT_ACCESS.key?(call.name) &&
            resolve_reference(call.receiver, environment).equal?(TX)
        end

        def helper_call?(call, environment)
          @methods.key?(call.name) &&
            (call.positional + call.keywords.values.compact).any? do |argument|
              resolve_value(argument, environment).equal?(TX)
            end
        end

        def record_statement!(operation, call, environment)
          label_node = call.positional.fetch(0) do
            raise ConfigurationError,
                  "SQLite statement call #{call.name.inspect} has no label"
          end
          label = resolve_label(label_node, environment)
          access = STATEMENT_ACCESS.fetch(call.name)
          existing = @source.fetch(operation)[label]
          if existing && existing != access
            raise ConfigurationError,
                  "SQLite statement #{label.inspect} has conflicting access modes"
          end
          @source.fetch(operation)[label] = access.freeze
        end

        def inspect_helper(call, operation, caller_environment)
          definition = @methods.fetch(call.name)
          identity = [operation, call.name]
          if @call_stack.include?(identity)
            raise ConfigurationError,
                  "recursive boundary helper #{call.name.inspect} is unsupported"
          end

          environment = bind_arguments(definition, call, caller_environment)
          @visited_methods << call.name
          @call_stack << identity
          inspect_node(definition.body, operation, environment)
        ensure
          @call_stack.pop if @call_stack.last == identity
        end

        def bind_arguments(definition, call, caller_environment)
          if call.positional.length < definition.required_parameters.length
            raise ConfigurationError,
                  "boundary helper #{definition.name.inspect} has missing arguments"
          end

          environment = {}
          definition.required_parameters.each_with_index do |name, index|
            environment[name] = resolve_value(
              call.positional.fetch(index),
              caller_environment
            )
          end
          definition.keyword_parameters.each do |name|
            argument = call.keywords[name]
            environment[name] = if argument
                                  resolve_value(argument, caller_environment)
                                elsif call.keywords.key?(name)
                                  caller_environment.fetch(name, UNKNOWN)
                                else
                                  UNKNOWN
                                end
          end
          environment
        end

        def compare_registry!
          registry_operations = @registry.document.fetch("operations").to_h do |entry|
            [entry.fetch("operation"), entry]
          end
          source_names = @source.keys.to_set
          registry_names = registry_operations.keys.to_set
          compare_sets!("operations", source_names, registry_names)

          source_names.each do |operation|
            source_statements = @source.fetch(operation)
            registry_statements = registry_operations.fetch(operation)
                                                    .fetch("statements")
                                                    .to_h do |entry|
              [entry.fetch("template"), entry.fetch("access")]
            end
            compare_sets!(
              "statements for #{operation}",
              source_statements.keys.to_set,
              registry_statements.keys.to_set
            )
            source_statements.each do |label, access|
              next if registry_statements.fetch(label) == access

              raise ConfigurationError,
                    "SQLite statement #{operation}/#{label} access mode disagrees"
            end
          end
        end

        def compare_sets!(name, source, registry)
          missing_registry = source - registry
          missing_source = registry - source
          return if missing_registry.empty? && missing_source.empty?

          details = []
          unless missing_registry.empty?
            details << "absent from registry: #{missing_registry.to_a.sort.join(", ")}"
          end
          unless missing_source.empty?
            details << "absent from source: #{missing_source.to_a.sort.join(", ")}"
          end
          raise ConfigurationError, "boundary #{name} mismatch (#{details.join("; ")})"
        end

        def resolve_label(node, environment)
          value = resolve_value(node, environment, label: true)
          return value if value.is_a?(String)

          raise ConfigurationError, "SQLite statement label is not statically bounded"
        end

        def resolve_value(node, environment, label: false)
          return UNKNOWN unless node.is_a?(Array)

          case node.fetch(0, nil)
          when :string_literal
            resolve_string(node, environment, allow_index: label)
          when :var_ref, :vcall
            environment.fetch(identifier(node), UNKNOWN)
          when :symbol_literal
            symbol_name(node)
          else
            UNKNOWN
          end
        end

        def resolve_string(node, environment, allow_index: false)
          content = node.fetch(1).drop(1)
          return "" if content.empty?

          fragments = []
          content.each_with_index do |part, index|
            case part.fetch(0, nil)
            when :@tstring_content
              fragments << part.fetch(1)
            when :string_embexpr
              expression = part.dig(1, 0)
              value = resolve_value(expression, environment, label: true)
              if allow_index &&
                 !value.is_a?(String) &&
                 reviewed_index_expression?(expression) &&
                 index == content.length - 1 &&
                 DYNAMIC_INDEX_PREFIXES.include?(fragments.join)
                value = "{index}"
              end
              unless value.is_a?(String)
                raise ConfigurationError,
                      "unreviewed SQLite statement label interpolation at line " \
                      "#{source_line(expression)}"
              end
              fragments << value
            else
              raise ConfigurationError,
                    "unsupported SQLite statement label expression"
            end
          end
          fragments.join
        end

        def reviewed_index_expression?(node)
          return true if %i[var_ref vcall].include?(node.fetch(0, nil)) &&
                         identifier(node) == "index"

          call = parse_call(node)
          return false unless call&.name == "fetch" && call.positional.length == 1
          return false unless identifier(call.receiver) == "write"

          resolve_value(call.positional.first, {}) == "write_index"
        end

        def resolve_reference(node, environment)
          environment.fetch(identifier(node), UNKNOWN)
        end

        def transaction_operation(call)
          operation_node = call.keywords["operation"]
          unless operation_node
            raise ConfigurationError,
                  "boundary operation must declare an operation literal"
          end

          operation = resolve_value(operation_node, {})
          unless operation.is_a?(String)
            raise ConfigurationError, "boundary operation must be a String literal"
          end
          operation
        end

        def transaction_call?(call)
          call && TRANSACTION_METHODS.include?(call.name)
        end

        def parse_call(node)
          return nil unless node.is_a?(Array)

          case node.fetch(0, nil)
          when :method_add_arg
            base_name, receiver = call_target(node.fetch(1))
            return nil unless base_name

            positional, keywords = call_arguments(node.fetch(2))
          when :command
            base_name = identifier(node.fetch(1))
            receiver = nil
            positional, keywords = call_arguments(node.fetch(2))
          when :command_call
            base_name = identifier(node.fetch(3))
            receiver = node.fetch(1)
            positional, keywords = call_arguments(node.fetch(4))
          when :call, :fcall, :vcall
            base_name, receiver = call_target(node)
            return nil unless base_name

            positional = []
            keywords = {}
          else
            return nil
          end

          if %w[__send__ public_send send].include?(base_name)
            return Call.new(
              name: base_name.freeze,
              receiver:,
              positional: positional.freeze,
              keywords: keywords.freeze
            ) if positional.empty?

            dispatched = symbol_name(positional.first)
            unless dispatched
              raise ConfigurationError,
                    "dynamic dispatch is forbidden in boundary source"
            end

            base_name = dispatched
            positional = positional.drop(1)
          end
          Call.new(
            name: base_name.freeze,
            receiver:,
            positional: positional.freeze,
            keywords: keywords.freeze
          )
        end

        def call_target(node)
          case node.fetch(0, nil)
          when :call
            [identifier(node.fetch(3)), node.fetch(1)]
          when :fcall, :vcall
            [identifier(node), nil]
          else
            [nil, nil]
          end
        end

        def call_arguments(node)
          arguments = case node&.fetch(0, nil)
                      when :arg_paren
                        node.dig(1, 1) || []
                      when :args_add_block
                        node.fetch(1)
                      else
                        []
                      end
          positional = []
          keywords = {}
          arguments.each do |argument|
            if argument.fetch(0, nil) == :bare_assoc_hash
              associations = argument.fetch(1)
              if associations.all? { |entry| entry.dig(1, 0) == :@label }
                associations.each do |association|
                  key = association.dig(1, 1).delete_suffix(":")
                  keywords[key] = association.fetch(2)
                end
              else
                positional << argument
              end
            else
              positional << argument
            end
          end
          [positional, keywords]
        end

        def method_definition(node)
          required, keywords = method_parameters(node.fetch(2))
          MethodDefinition.new(
            name: identifier(node.fetch(1)).freeze,
            required_parameters: required.freeze,
            keyword_parameters: keywords.freeze,
            body: node.fetch(3)
          )
        end

        def method_parameters(node)
          parameters = node.fetch(0, nil) == :paren ? node.fetch(1) : node
          return [[], []] unless parameters&.fetch(0, nil) == :params

          required = Array(parameters.fetch(1)).map { |entry| identifier(entry) }
          keywords = Array(parameters.fetch(5)).map do |entry|
            entry.dig(0, 1).delete_suffix(":")
          end
          [required, keywords]
        end

        def block_parameter(block)
          parameters = block.dig(1, 1)
          return nil unless parameters&.fetch(0, nil) == :params

          required = Array(parameters.fetch(1))
          return nil unless required.length == 1

          identifier(required.first)
        end

        def block_body(block)
          block.fetch(2)
        end

        def identifier(node)
          return nil unless node.is_a?(Array)

          if node.fetch(0, nil).to_s.start_with?("@")
            return node.fetch(1)
          end
          case node.fetch(0, nil)
          when :var_ref, :vcall, :fcall
            identifier(node.fetch(1))
          when :call
            identifier(node.fetch(3))
          end
        end

        def symbol_name(node)
          return nil unless node.is_a?(Array) &&
                            node.fetch(0, nil) == :symbol_literal

          identifier(node.dig(1, 1))
        end

        def inspect_forbidden!(node)
          return unless node.is_a?(Array)

          constant = constant_name(node)
          if constant == "SQLite3::Database"
            raise ConfigurationError,
                  "direct SQLite3::Database use is forbidden in boundary source"
          end
          if FILESYSTEM_CONSTANTS.include?(constant)
            raise ConfigurationError,
                  "filesystem constant #{constant} is forbidden in boundary source"
          end

          call = parse_call(node)
          if call
            receiver = constant_name(call.receiver)
            if call.name == "execute" &&
               !%w[tx].include?(identifier(call.receiver))
              raise ConfigurationError,
                    "direct execute outside Transaction is forbidden in boundary source"
            end
            if FILESYSTEM_CONSTANTS.include?(receiver) &&
               FILE_MUTATIONS.include?(call.name)
              raise ConfigurationError,
                    "filesystem mutation #{receiver}.#{call.name} is forbidden"
            end
            if DYNAMIC_EXECUTION.include?(call.name)
              raise ConfigurationError,
                    "dynamic execution #{call.name} is forbidden in boundary source"
            end
          end
          node.each { |child| inspect_forbidden!(child) if child.is_a?(Array) }
        end

        def constant_name(node)
          return nil unless node.is_a?(Array)

          case node.fetch(0, nil)
          when :var_ref
            child = node.fetch(1)
            child.fetch(1) if child.fetch(0, nil) == :@const
          when :const_path_ref
            [constant_name(node.fetch(1)), identifier(node.fetch(2))]
              .compact
              .join("::")
          end
        end

        def source_line(node)
          return "unknown" unless node.is_a?(Array)
          if node.fetch(0, nil).to_s.start_with?("@")
            return node.dig(2, 0) || "unknown"
          end

          node.each do |child|
            next unless child.is_a?(Array)

            line = source_line(child)
            return line unless line == "unknown"
          end
          "unknown"
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
          when Array
            value.each { |entry| deep_freeze(entry) }
          end
          value.freeze
        end
      end

      private_constant :Auditor, :Call, :DYNAMIC_EXECUTION,
                       :DYNAMIC_INDEX_PREFIXES, :FILESYSTEM_CONSTANTS,
                       :FILE_MUTATIONS, :MAX_SOURCE_BYTES,
                       :MethodDefinition, :STATEMENT_ACCESS,
                       :TRANSACTION_METHODS, :TX, :UNKNOWN
    end

    private_constant :BoundarySourceAudit
  end
end

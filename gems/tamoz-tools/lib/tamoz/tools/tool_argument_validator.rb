# frozen_string_literal: true

module Tamoz
  module Tools
    # Validates tool arguments before dispatch or effect planning.
    # :reek:FeatureEnvy :reek:DuplicateMethodCall -- validation is deliberately
    # expressed against the supplied path resolver and skill catalog boundaries.
    # :reek:ControlParameter :reek:LongParameterList :reek:TooManyMethods -- this
    # class is the protocol boundary; keeping operation-specific checks together
    # makes the complete accepted surface auditable in one place.
    # :reek:UncommunicativeVariableName -- the rescue binding is intentionally the
    # conventional short-lived exception variable required by the style gate.
    # :reek:TooManyStatements :reek:RepeatedConditional -- the tool protocol's
    # per-operation checks are kept together so every exposed argument is audited.
    # :reek:MissingSafeMethod -- invalid arguments must raise typed boundary errors.
    class ToolArgumentValidator
      VALIDATORS = {
        'read_file' => :validate_read_file,
        'list_directory' => :validate_list_directory,
        'search_text' => :validate_search,
        'apply_patch' => :validate_patch,
        'run_check' => :validate_check,
        'load_skill' => :validate_load_skill,
        'read_skill_resource' => :validate_skill_resource,
        'create_file' => :validate_create_file
      }.freeze

      def initialize(names:, checks:, path_resolver:, skill_catalog:)
        @names = names
        @checks = checks
        @path_resolver = path_resolver
        @skill_catalog = skill_catalog
        freeze
      end

      def validate(name, arguments)
        normalized_name = String(name)
        raise ToolError, "unknown tool #{normalized_name.inspect}" unless @names.include?(normalized_name)
        raise ToolArgumentError, 'tool arguments must be an object' unless arguments.is_a?(Hash)

        normalized_arguments = arguments.transform_keys(&:to_s)
        normalized_arguments = validate_operation(normalized_name, normalized_arguments)
        normalized_arguments.freeze
      rescue KeyError => e
        raise ToolArgumentError, "missing tool argument #{e.key.inspect}"
      end

      private

      def validate_operation(name, arguments)
        return arguments unless VALIDATORS.key?(name)

        send(VALIDATORS.fetch(name), arguments)
      end

      def validate_read_file(arguments)
        validate_path_only(arguments, %w[path], 'path')
      end

      def validate_list_directory(arguments)
        validate_path_only(arguments, %w[path], 'path', '.')
      end

      def validate_path_only(arguments, allowed, key, default = nil)
        reject_unknown!(arguments, allowed)
        validate_path_argument!(arguments.fetch(key, default))
        arguments
      end

      def validate_search(arguments)
        validate_path_only(arguments, %w[path query], 'path', '.')
        query = arguments.fetch('query')
        raise ToolArgumentError, 'query must be a string' unless query.is_a?(String)
        raise ToolArgumentError, 'query must not be empty' if query.empty?
        raise ToolArgumentError, 'query exceeds 256 bytes' if query.bytesize > 256
        raise ToolPolicyError, 'query must not contain a null byte' if query.include?("\0")
        raise ToolArgumentError, 'query must be UTF-8 encoded' unless query.encoding == Encoding::UTF_8
        raise ToolArgumentError, 'query must be valid UTF-8' unless query.valid_encoding?

        arguments
      end

      def validate_patch(arguments)
        validate_path_argument!(arguments.fetch('path'))
        validate_digest(arguments)
        has_legacy = arguments.key?('before') || arguments.key?('after')
        has_compound = arguments.key?('replacements')
        if has_legacy && has_compound
          raise ToolArgumentError, 'apply_patch accepts either before/after or replacements, not both'
        end

        has_compound ? validate_compound_patch(arguments) : validate_legacy_patch(arguments)
        arguments
      end

      def validate_digest(arguments)
        return unless arguments.key?('expected_sha256')

        digest = arguments.fetch('expected_sha256')
        return if digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

        raise ToolArgumentError, 'expected_sha256 must be 64 lowercase hex characters'
      end

      def validate_compound_patch(arguments)
        reject_unknown!(arguments, %w[expected_sha256 path replacements])
        replacements = arguments.fetch('replacements')
        unless replacements.is_a?(Array) && !replacements.empty?
          raise ToolArgumentError, 'replacements must be a non-empty array'
        end
        if replacements.length > Toolbox::MAX_REPLACEMENTS
          raise ToolArgumentError, "replacements exceeds #{Toolbox::MAX_REPLACEMENTS}"
        end

        replacements.each_with_index { |entry, index| validate_replacement(entry, index) }
      end

      def validate_replacement(entry, index)
        raise ToolArgumentError, "replacements[#{index}] must be an object" unless entry.is_a?(Hash)
        unless entry.key?('before') && entry.key?('after')
          raise ToolArgumentError, "replacements[#{index}] must contain before and after keys"
        end

        validate_patch_text!(entry.fetch('before'), name: "replacements[#{index}].before", empty: false)
        validate_patch_text!(entry.fetch('after'), name: "replacements[#{index}].after", empty: true)
        unknown = entry.keys - %w[before after]
        return if unknown.empty?

        raise ToolArgumentError,
              "replacements[#{index}] has unknown keys: #{unknown.sort.join(', ')}"
      end

      def validate_legacy_patch(arguments)
        reject_unknown!(arguments, %w[after before expected_sha256 path])
        validate_patch_text!(arguments.fetch('before'), name: 'before', empty: false)
        validate_patch_text!(arguments.fetch('after'), name: 'after', empty: true)
      end

      def validate_check(arguments)
        reject_unknown!(arguments, %w[name])
        check_name = arguments.fetch('name')
        raise ToolArgumentError, 'check name must be a string' unless check_name.is_a?(String)
        return arguments if @checks.key?(check_name)

        raise ToolArgumentError, "unknown configured check #{check_name.inspect}"
      end

      def validate_load_skill(arguments)
        reject_unknown!(arguments, %w[skill])
        validate_skill_reference!(arguments.fetch('skill'))
        arguments
      end

      def validate_skill_resource(arguments)
        reject_unknown!(arguments, %w[skill path])
        record = validate_skill_reference!(arguments.fetch('skill'))
        path = arguments.fetch('path')
        raise ToolArgumentError, 'path must be a string' unless path.is_a?(String)
        raise ToolArgumentError, 'path exceeds 1024 bytes' if path.bytesize > 1024

        Skills.read_resource_entry!(record, path)
        arguments
      end

      def validate_create_file(arguments)
        reject_unknown!(arguments, %w[path content expected_sha256 mode])
        validate_path_argument!(arguments.fetch('path'))
        validate_file_text!(arguments.fetch('content'))
        arguments = validate_content_digest(arguments)
        mode = arguments.fetch('mode', '0644')
        validate_mode!(mode)
        validate_create_path!(arguments.fetch('path'))
        arguments.key?('mode') ? arguments : arguments.merge('mode' => mode)
      end

      def validate_content_digest(arguments)
        unless arguments.key?('expected_sha256')
          return arguments.merge('expected_sha256' => Digest::SHA256.hexdigest(arguments.fetch('content')))
        end

        expected = arguments.fetch('expected_sha256')
        unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)
          raise ToolArgumentError, 'expected_sha256 must be 64 lowercase hex characters'
        end

        actual = Digest::SHA256.hexdigest(arguments.fetch('content'))
        return arguments if actual == expected

        raise ToolArgumentError, "content digest mismatch: expected #{expected}, computed #{actual}"
      end

      def validate_skill_reference!(reference)
        raise ToolArgumentError, 'skill must be a string' unless reference.is_a?(String)
        raise ToolArgumentError, 'skill exceeds 256 bytes' if reference.bytesize > 256

        @skill_catalog.resolve(reference)
      end

      def validate_file_text!(value)
        raise ToolArgumentError, 'content must be a string' unless value.is_a?(String)
        if value.bytesize > Toolbox::MAX_FILE_BYTES
          raise ToolArgumentError, "content exceeds #{Toolbox::MAX_FILE_BYTES} bytes"
        end
        raise ToolPolicyError, 'content must not contain a null byte' if value.include?("\0")
        raise ToolArgumentError, 'content must be UTF-8 encoded' unless value.encoding == Encoding::UTF_8
        raise ToolArgumentError, 'content must be valid UTF-8' unless value.valid_encoding?
      end

      def validate_mode!(value)
        raise ToolArgumentError, 'mode must be a string' unless value.is_a?(String)
        return if value.match?(/\A0[0-7]{3}\z/)

        raise ToolArgumentError, 'mode must be an octal permission string (e.g. "0644")'
      end

      def validate_path_argument!(raw_path)
        @path_resolver.validate_path_argument!(raw_path)
      end

      def validate_create_path!(raw_path)
        @path_resolver.validate_create_path!(raw_path)
      end

      def validate_patch_text!(value, name:, empty:)
        raise ToolArgumentError, "#{name} must be a string" unless value.is_a?(String)
        raise ToolArgumentError, "#{name} must not be empty" if !empty && value.empty?
        if value.bytesize > Toolbox::MAX_PATCH_BYTES
          raise ToolArgumentError, "#{name} exceeds #{Toolbox::MAX_PATCH_BYTES} bytes"
        end
        raise ToolPolicyError, "#{name} must not contain a null byte" if value.include?("\0")
        raise ToolArgumentError, "#{name} must be UTF-8 encoded" unless value.encoding == Encoding::UTF_8
        raise ToolArgumentError, "#{name} must be valid UTF-8" unless value.valid_encoding?
      end

      def reject_unknown!(arguments, allowed)
        unknown = arguments.keys - allowed
        return if unknown.empty?

        raise ToolArgumentError, "unknown tool arguments: #{unknown.sort.join(', ')}"
      end
    end
  end
end

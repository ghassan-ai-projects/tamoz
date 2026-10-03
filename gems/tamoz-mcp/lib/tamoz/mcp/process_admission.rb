# frozen_string_literal: true

module Tamoz
  module Mcp
    # Admits the operator-owned executable, workspace and inherited environment.
    class ProcessAdmission
      def validate_process_surface!(transport:, command:, arguments:, env_allowlist:, working_directory:, workspace:)
        if transport == :http
          unless command.nil? && arguments.empty? && env_allowlist.empty? && working_directory.nil?
            raise ValidationError,
                  'HTTP MCP servers cannot configure a command, argv, environment, or working directory'
          end

          return [nil, nil]
        end

        [validate_command!(command, workspace), validate_working_directory!(working_directory, workspace)]
      end

      def validate_workspace_root!(value)
        return nil if value.nil?
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, 'workspace_root must be an absolute path when supplied'
        end

        File.realpath(value)
      rescue Errno::ENOENT
        raise ValidationError, "workspace_root does not exist: #{value.inspect}"
      end

      def validate_command!(value, workspace)
        validate_command_path!(value)
        validate_command_outside_workspace!(value, workspace) if workspace

        value.dup.freeze
      end

      def validate_command_path!(value)
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, "command must be an absolute path, got #{value.inspect}"
        end
        raise ValidationError, "command must not be a symlink: #{value.inspect}" if File.symlink?(value)
        raise ValidationError, "command does not exist or is not a file: #{value.inspect}" unless File.file?(value)
        return if File.executable?(value)

        raise ValidationError, "command is not executable: #{value.inspect}"
      end

      def validate_command_outside_workspace!(value, workspace)
        real = File.realpath(value)
        return unless real == workspace || real.start_with?("#{workspace}#{File::SEPARATOR}")

        raise ValidationError, "command must not be inside the agent workspace: #{value.inspect}"
      end

      def validate_arguments!(value)
        raise ValidationError, 'arguments must be an array of strings' unless value.is_a?(Array)

        value.map { |element| validate_argument_element!(element) }.freeze
      end

      def validate_argument_element!(element)
        raise ValidationError, "arguments elements must be strings, got #{element.class}" unless element.is_a?(String)
        raise ValidationError, 'arguments element contains a NUL byte' if element.include?("\x00")
        if CONTROL_CHARACTER_PATTERN.match?(element)
          raise ValidationError, 'arguments element contains a control character'
        end
        if element.bytesize > MAX_ARGUMENT_BYTES
          raise ValidationError, "arguments element exceeds #{MAX_ARGUMENT_BYTES} bytes"
        end
        if SHELL_METACHARACTER_PATTERN.match?(element)
          raise ValidationError,
                "arguments element #{element.inspect} contains shell metacharacters"
        end

        element.dup.freeze
      end

      def validate_env_allowlist!(value)
        raise ValidationError, 'env_allowlist must be an array of environment variable names' unless value.is_a?(Array)

        value.map do |name|
          unless name.is_a?(String) && ENV_NAME_PATTERN.match?(name)
            raise ValidationError, "env_allowlist entries must be valid names, got #{name.inspect}"
          end
          if ServerConfig.credential_env_name?(name)
            raise ValidationError,
                  "env_allowlist entry #{name.inspect} is credential-shaped; " \
                  'use credential_refs for explicit credential names'
          end

          name.dup.freeze
        end.freeze
      end

      def validate_working_directory!(value, workspace)
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, "working_directory must be an absolute path, got #{value.inspect}"
        end
        raise ValidationError, "working_directory does not exist: #{value.inspect}" unless File.directory?(value)

        real = File.realpath(value)
        if workspace && real == workspace
          raise ValidationError, 'working_directory must not be the agent workspace root'
        end

        value.dup.freeze
      end
    end
    private_constant :ProcessAdmission
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # One configured check's specification: a name, an argv, and a safety class.
      #
      # This is the profile's execution surface, so it is the strictest validator
      # in the loader and it is split out for that reason. A configured check runs
      # with the UNTRUSTED WORKSPACE as its working directory, so the rules here
      # exist to stop repository content from naming the program that runs:
      # argv is a program and its arguments, never a command string; argv[0] is
      # never a shell or an interpreter that takes inline source; and a relative
      # argv[0] containing a separator would resolve inside the workspace, which
      # invariant 35 forbids.
      #
      # Pinned by test/agent_profile_test.rb (shell metacharacters, relative and
      # dot programs) and test/agent_profile_schema_seams_test.rb (check name,
      # argv element types).
      # :reek:MissingSafeMethod — every step is a refusal that raises; a predicate
      # twin would invite checking the execution surface without enforcing it.
      # :reek:TooManyStatements — `validate_argv!` is the shape check, the
      # per-element sweep and the return of the validated argv.
      # :reek:NilCheck — File::ALT_SEPARATOR is nil on POSIX; that IS the question.
      class CheckSpecValidator
        MAX_ARGV_ELEMENT_BYTES = 4096

        # Validates every check in the document and returns the checks mapping.
        def self.call(hash, path)
          checks = hash['checks'] || {}
          raise ValidationError, "#{path}: checks must be a mapping" unless checks.is_a?(Hash)

          checks.each { |name, check| new(name, check, path).validate! }
          checks
        end

        def initialize(name, check, path)
          @name = name
          @check = check
          @path = path
        end

        def validate!
          validate_name!
          validate_shape!
          argv = validate_argv!
          validate_program!(argv.first)
          validate_safety!
        end

        private

        def validate_name!
          return if @name.is_a?(String) && PROFILE_ID_PATTERN.match?(@name)

          raise ValidationError, "#{@path}: invalid check name #{@name.inspect}"
        end

        def validate_shape!
          raise ValidationError, "#{problem} must be a mapping" unless @check.is_a?(Hash)

          unknown = @check.keys - CHECK_KEYS
          return if unknown.empty?

          raise ValidationError, "#{@path}: unknown check fields #{unknown.sort.inspect}"
        end

        def validate_argv!
          argv = @check['argv']
          unless argv.is_a?(Array) && !argv.empty? &&
                 argv.all? { |entry| entry.is_a?(String) && !entry.empty? }
            raise ValidationError, "#{problem} argv must be a non-empty string array"
          end

          argv.each { |element| validate_argv_element!(element) }
          argv
        end

        # An argv element is data handed to a program. These four refusals keep it
        # from being anything else — a truncation, a terminal escape, an unbounded
        # blob, or a fragment of shell.
        def validate_argv_element!(element)
          raise ValidationError, "#{problem} argv contains a NUL byte" if element.include?("\0")

          if CONTROL_CHARACTER_PATTERN.match?(element)
            raise ValidationError, "#{problem} argv contains a control character"
          end
          if element.bytesize > MAX_ARGV_ELEMENT_BYTES
            raise ValidationError, "#{problem} argv element exceeds #{MAX_ARGV_ELEMENT_BYTES} bytes"
          end
          return unless SHELL_METACHARACTER_PATTERN.match?(element)

          raise ValidationError,
                "#{problem} argv element #{element.inspect} contains shell metacharacters"
        end

        # argv[0] names the program that will actually run. A shell, an interpreter
        # that takes inline source, or a wrapper that re-executes another argv turns
        # the rest of argv into a program, which is exactly the injection the plan
        # forbids. Leading dashes are rejected so argv[0] cannot be smuggled as an
        # option to a downstream launcher.
        def validate_program!(program)
          unless program.is_a?(String) && !program.empty?
            raise ValidationError, "#{problem} argv[0] must be a program name"
          end

          prefix = program_problem(program)
          raise ValidationError, "#{prefix} must not start with '-'" if program.start_with?('-')
          raise ValidationError, "#{prefix} must not be a directory" if program.end_with?(File::SEPARATOR)

          refuse_workspace_relative!(program)
          refuse_wrapper!(program)
        end

        # P8-E: a configured check runs with the *untrusted workspace* as its working
        # directory, so a relative argv[0] that contains a separator ("bin/check",
        # "./tools/run") names a file the repository supplies. That is content
        # granting itself execution, which invariant 35 forbids. A bare program name
        # is resolved through PATH (which never contains the workspace) and an
        # absolute path names an operator-chosen program, so both remain allowed.
        def refuse_workspace_relative!(program)
          return unless separator?(program) && !program.start_with?(File::SEPARATOR)

          raise ValidationError,
                "#{program_problem(program)} is a relative path; " \
                'it would resolve inside the untrusted workspace. Use an absolute path or a ' \
                'bare program name resolved through PATH'
        end

        def refuse_wrapper!(program)
          basename = File.basename(program).downcase.sub(/\.(exe|bat|cmd|com)\z/, '')
          prefix = program_problem(program)
          raise ValidationError, "#{prefix} is not a program" if ['.', '..'].include?(basename)
          return unless ARGV0_DENYLIST.include?(basename)

          raise ValidationError,
                "#{prefix} is a shell or " \
                'interpreter wrapper; a profile check names a program, not a command string'
        end

        # True when the value carries a path separator for this platform.
        #
        # :reek:UtilityFunction — a pure platform question about one string.
        def separator?(value)
          return true if value.include?(File::SEPARATOR)

          alternate = File::ALT_SEPARATOR
          !alternate.nil? && value.include?(alternate)
        end

        def validate_safety!
          return if SAFETIES.include?(@check['safety'])

          raise ValidationError, "#{problem} safety must be one of #{SAFETIES.inspect}"
        end

        # Every refusal names the file and the check it is talking about; these two
        # keep that prefix in one place so the messages cannot drift apart.
        def problem
          "#{@path}: check #{@name.inspect}"
        end

        def program_problem(program)
          "#{problem} argv[0] #{program.inspect}"
        end
      end
    end
  end
end

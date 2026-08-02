# frozen_string_literal: true

require "digest"
require "fileutils"
require "forwardable"
require "json"
require "pathname"
require "psych"

module Tamoz
  module Agent
    # Operator-owned trusted profile (P8). A profile is authority: it pins the
    # canonical root identity, named argv checks, symbolic model roles, budgets,
    # capability/policy versions, and approval defaults for a durable session.
    # Profiles live outside any repository; repository suggestions are evidence
    # only and never become authority without explicit operator adoption.
    #
    # Loading fails closed: no code execution, no aliases beyond a small count,
    # no interpolation, no embedded secrets, strict schema allowlist, owner-only
    # file permissions, and a canonical digest over the normalized data model.
    class Profile
      extend Forwardable

      SCHEMA_VERSION = 1
      MAX_BYTES = 128 * 1024
      MAX_ALIASES = 32
      MAX_NESTING = 16
      # O_NOFOLLOW makes the *open* refuse a symlink, so validation and reading
      # share one file description and a swap between them cannot be observed.
      NOFOLLOW = File::Constants.const_defined?(:NOFOLLOW) ? File::Constants::NOFOLLOW : 0
      DIGEST_DOMAIN = "tamoz.profile.v1\n"
      DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
      PROFILE_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,63}\z/
      PROFILE_VERSION_PATTERN = /\A[-_.A-Za-z0-9]{1,128}\z/
      CREDENTIAL_REF_PATTERN = /\ATAMOZ_[A-Z0-9_]+\z/
      SUGGESTION_DIRECTORY = ".tamoz"
      SUGGESTION_BASENAME = "suggested-profile.yaml"

      SAFETIES = %w[read_only idempotent unsafe].freeze
      KNOWN_TOOLS = %w[read_file list_directory search_text apply_patch create_file run_check].freeze
      KNOWN_PROVIDERS = RubyLLMModel::ENV_KEYS.keys.map(&:to_s).freeze

      TOP_LEVEL_KEYS = %w[profile roots model_roles budgets checks tools policy].freeze
      PROFILE_KEYS = %w[schema_version profile_id profile_version canonical_root description].freeze
      ROOTS_KEYS = %w[workspace].freeze
      MODEL_ROLE_KEYS = %w[provider model credential_ref].freeze
      CREDENTIAL_REF_KEYS = %w[kind name].freeze
      BUDGET_KEYS = %w[cost_usd input_tokens output_tokens wall_clock_seconds steps].freeze
      CHECK_KEYS = %w[argv safety].freeze
      TOOLS_KEYS = %w[allowed approval_required].freeze
      POLICY_KEYS = %w[
        allow_changes default_check_safety graph_version behavior_version tool_catalog_digest
      ].freeze

      # A configured check is an exact argv executed without a shell. Metacharacters
      # are meaningless to `exec`, so rejecting them is defence in depth; the vector
      # that actually matters is argv[0]. `["bash", "-c", "rm -rf /"]` contains no
      # metacharacter at all, so a metacharacter scan alone does not stop command
      # injection. P8-E therefore rejects interpreter and wrapper argv[0] values
      # outright: a profile names a program, never a shell to interpret a string.
      SHELL_METACHARACTER_PATTERN = /[$;|><`*&]/
      # C0 controls plus DEL. Newlines in argv corrupt every downstream log,
      # prompt, and receipt that renders the command.
      CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/
      ARGV0_DENYLIST = %w[
        sh bash zsh dash ksh mksh pdksh csh tcsh fish ash busybox rbash
        env eval exec source command builtin xargs nohup setsid nice ionice
        stdbuf time timeout script su sudo doas runuser chroot unshare
        perl python python2 python3 osascript powershell pwsh cmd
      ].freeze

      SECRET_KEY_DENYLIST = %w[api_key password token secret api_base].freeze
      INTERPOLATION_PATTERN = /\$\{|\%\{|\{\{|<%|%>/.freeze
      SECRET_VALUE_PATTERNS = [
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
        /\b(sk|pk|xox[baprs])-[A-Za-z0-9][A-Za-z0-9_-]{7,}/,
        /\bAKIA[0-9A-Z]{16}\b/,
        /\bAIza[0-9A-Za-z_-]{35}\b/
      ].freeze
      # Long unbroken tokens outside allowlisted fields are treated as candidate
      # secrets. Pure hex (digests) and path segments are excluded.
      ENTROPY_PATTERN = /\b(?![0-9a-f]{32,}\b)[A-Za-z0-9_+\/=-]{40,}\b/.freeze
      # Fields whose values are legitimately long tokens (paths, digests) are
      # exempt from the entropy heuristic.
      ENTROPY_EXEMPT_KEYS = %w[canonical_root workspace tool_catalog_digest].freeze
      TIMEZONE_WORDS = %w[local system host].freeze

      ProfileError = Class.new(Tamoz::Agent::Error)
      PermissionError = Class.new(ProfileError)
      ValidationError = Class.new(ProfileError)
      AdoptionError = Class.new(ProfileError)

      Fields = Data.define(
        :profile_id, :profile_version, :canonical_root, :description,
        :model_roles, :budgets, :checks, :tools_allowed, :tools_approval_required,
        :policy, :canonical_digest, :suggestion, :pinned
      ) do
        def initialize(pinned: false, **members)
          super(pinned:, **Profile.deep_freeze(members))
        end

        def allow_changes? = policy.fetch("allow_changes")
        def high_risk? = model_roles.values.any? { |role| role.key?("credential_ref") }
      end

      attr_reader :fields

      def initialize(fields)
        @fields = fields
        freeze
      end

      def_delegators :fields,
                     :profile_id, :profile_version, :canonical_root, :description,
                     :model_roles, :budgets, :checks, :tools_allowed,
                     :tools_approval_required, :policy, :canonical_digest,
                     :suggestion, :pinned, :allow_changes?, :high_risk?

      # P8-B §5.1/§5.4: the exact capability authority a durable session was
      # started under, in a form that can be replayed from the checkpoint alone.
      # Credential references are stripped: a checkpoint never carries anything
      # credential-shaped (invariant 24), and nothing here can widen authority
      # because reconstruction re-runs the same validators (invariant 35).
      def authority_snapshot
        Profile.deep_freeze(
          "profile_id" => profile_id,
          "profile_version" => profile_version,
          "canonical_digest" => canonical_digest,
          "canonical_root" => canonical_root,
          "model_roles" => model_roles.transform_values do |role|
            role.reject { |key, _| key == "credential_ref" }
          end,
          "checks" => checks,
          "tools" => {
            "allowed" => tools_allowed,
            "approval_required" => tools_approval_required
          },
          "policy" => policy
        )
      end

      def self.load(path, env: ENV, adoption_registry: nil, confirm_adoption: nil)
        expanded = File.expand_path(File.path(path))
        document = load_document(expanded, suggestion: false)
        registry = adoption_registry || AdoptionRegistry.new(env:)
        unless registry.activated?(document.profile_id, document.canonical_digest)
          confirmed = confirm_adoption&.call(document)
          unless confirmed
            raise AdoptionError,
                  "profile #{document.profile_id.inspect} digest " \
                  "#{document.canonical_digest} is not activated in #{registry.path}"
          end

          registry.activate(document.profile_id, document.canonical_digest)
        end

        document
      end

      # Validation-only load used by `tamoz profile preview`. The suggestion flag
      # marks repository-provided files as evidence; it never grants authority.
      def self.preview(path, suggestion: false)
        load_document(File.expand_path(File.path(path)), suggestion:)
      end

      AUTHORITY_KEYS = %w[
        profile_id profile_version canonical_digest canonical_root model_roles checks tools policy
      ].freeze

      # P8-B §5.4/§5.5: rebuild the authority a session was pinned to from its
      # own checkpoint. The snapshot is treated as untrusted input and re-runs
      # every validator, so a corrupted or tampered checkpoint can only narrow
      # or fail, never widen. Model roles carry no credential reference, so a
      # replayed profile can never resolve a credential the operator did not
      # supply in the currently loaded profile.
      def self.from_authority(snapshot, source: "<pinned session authority>")
        unless snapshot.is_a?(Hash)
          raise ValidationError, "#{source}: pinned profile authority must be a mapping"
        end

        hash = normalize_keys(snapshot)
        unknown = hash.keys - AUTHORITY_KEYS
        unless unknown.empty?
          raise ValidationError, "#{source}: unknown pinned authority fields #{unknown.sort.inspect}"
        end
        missing = AUTHORITY_KEYS - hash.keys - %w[model_roles checks]
        unless missing.empty?
          raise ValidationError, "#{source}: pinned authority is missing #{missing.sort.inspect}"
        end

        digest = hash.fetch("canonical_digest")
        unless digest.is_a?(String) && DIGEST_PATTERN.match?(digest)
          raise ValidationError, "#{source}: pinned authority digest is not a sha256: digest"
        end

        validate_strings!(hash.reject { |key, _| key == "canonical_digest" }, source)
        synthetic = {
          "profile" => {
            "schema_version" => SCHEMA_VERSION,
            "profile_id" => hash.fetch("profile_id"),
            "profile_version" => hash.fetch("profile_version"),
            "canonical_root" => hash.fetch("canonical_root")
          },
          "roots" => {"workspace" => hash.fetch("canonical_root")},
          "model_roles" => hash["model_roles"] || {},
          "checks" => hash["checks"] || {},
          "tools" => hash.fetch("tools"),
          "policy" => hash.fetch("policy")
        }
        validate_profile_fields!(synthetic.fetch("profile"), source)
        validate_roots!(synthetic, synthetic.fetch("profile"), source)
        validate_model_roles!(synthetic, source)
        validate_checks!(synthetic, source)
        tools = validate_tools!(synthetic, source)
        validate_policy!(synthetic, tools, source)
        new(build_fields(synthetic, digest:, suggestion: false, pinned: true))
      end

      def self.suggestion_path?(expanded_path)
        Pathname.new(expanded_path).each_filename.include?(SUGGESTION_DIRECTORY)
      end

      # §3.3 search precedence: explicit flag > TAMOZ_PROFILE (path | id | cwd
      # relative) > TAMOZ_PROFILE_ID > XDG profile dir. Returns nil when nothing
      # was requested; the caller then proceeds without a profile.
      def self.resolve_path(profile: nil, profile_id: nil, env: ENV)
        explicit = profile || env["TAMOZ_PROFILE"]
        id = profile_id || env["TAMOZ_PROFILE_ID"]
        return resolve_explicit(explicit, env:) if explicit
        return File.join(profiles_dir(env:), "#{id}.yaml") if id

        nil
      end

      def self.resolve_explicit(value, env: ENV)
        text = String(value)
        return text if text.start_with?(File::SEPARATOR)
        return File.join(profiles_dir(env:), "#{text}.yaml") if PROFILE_ID_PATTERN.match?(text)

        File.expand_path(text, Dir.pwd)
      end

      def self.config_dir(env: ENV)
        # TAMOZ_CONFIG_HOME redirects the whole operator config tree (profiles,
        # adoption registry); it exists for sandboxed runs and tests.
        override = env["TAMOZ_CONFIG_HOME"]
        return File.expand_path(override) if override.to_s != ""

        if RUBY_PLATFORM.match?(/darwin/)
          File.expand_path("~/Library/Application Support/tamoz")
        else
          base = env["XDG_CONFIG_HOME"] || File.expand_path("~/.config")
          File.join(base, "tamoz")
        end
      end

      def self.profiles_dir(env: ENV)
        File.join(config_dir(env:), "profiles")
      end

      def self.adoption_path(env: ENV)
        File.join(config_dir(env:), "adoption.yaml")
      end

      def self.transitions_path(env: ENV)
        File.join(config_dir(env:), "transitions.yaml")
      end

      def self.load_document(expanded_path, suggestion:)
        unless suggestion
          if suggestion_path?(expanded_path)
            raise ValidationError,
                  "#{expanded_path} is inside #{SUGGESTION_DIRECTORY}/ and is evidence " \
                  "only; preview or import it instead of activating it"
          end
        end
        # P8-E: the same open file description is permission-checked and read, so
        # replacing the path with a symlink between the two cannot be exploited.
        bytes = open_verified(expanded_path, permissions: !suggestion) do |handle|
          read_bytes(handle, expanded_path)
        end
        scan_yaml!(bytes, expanded_path)
        data = safe_parse(bytes, expanded_path)
        unless data.is_a?(Hash)
          raise ValidationError, "#{expanded_path}: profile must be a YAML mapping"
        end

        hash = normalize_keys(data)
        hash.delete("adoption")
        validate_schema!(hash, expanded_path)
        digest = canonical_digest(hash)
        new(build_fields(hash, digest:, suggestion:))
      end

      def self.read_bytes(handle, path)
        stat = handle.stat
        raise ValidationError, "#{path}: not a regular file" unless stat.file?
        if stat.size > MAX_BYTES
          raise ValidationError, "#{path}: profile exceeds #{MAX_BYTES} bytes"
        end

        bytes = handle.read(MAX_BYTES + 1) || +""
        if bytes.bytesize > MAX_BYTES
          raise ValidationError, "#{path}: profile exceeds #{MAX_BYTES} bytes"
        end

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise ValidationError, "#{path}: profile is not valid UTF-8"
        end

        text
      end

      # Opens the profile without following a final symlink and verifies the
      # permission rules against the *open descriptor* (fstat), not against a
      # path that could be re-pointed afterwards.
      def self.open_verified(path, permissions: true)
        handle = File.open(path, File::RDONLY | NOFOLLOW)
        begin
          verify_handle!(handle, path) if permissions
          yield handle
        ensure
          handle.close
        end
      rescue Errno::ELOOP, Errno::EMLINK, Errno::EOPNOTSUPP
        raise PermissionError, "#{path}: profile must not be a symlink"
      rescue Errno::ENOENT
        raise ValidationError, "#{path}: profile file does not exist"
      rescue Errno::EISDIR
        raise ValidationError, "#{path}: profile must be a regular file"
      rescue Errno::EACCES, Errno::EPERM
        raise PermissionError, "#{path}: profile is not readable"
      end

      def self.verify_permissions!(path)
        open_verified(path) { nil }
        nil
      end

      def self.verify_handle!(handle, path)
        stat = handle.stat
        unless stat.file?
          raise PermissionError, "#{path}: profile must be a regular file"
        end
        unless stat.owned?
          raise PermissionError, "#{path}: profile must be owned by the effective user"
        end
        unless (stat.mode & 0o777) == 0o600
          raise PermissionError, "#{path}: profile mode must be exactly 0600"
        end

        verify_parents!(path)
      end

      def self.verify_parents!(path)
        directory = File.dirname(path)
        immediate = true
        loop do
          stat = File.stat(directory)
          mode = stat.mode
          sticky = (mode & 0o1000) != 0
          if (mode & 0o022) != 0 && !sticky
            raise PermissionError,
                  "#{directory}: profile directory must not be writable by group or other"
          end
          if immediate && (mode & 0o004) != 0 && !sticky && stat.owned?
            raise PermissionError,
                  "#{directory}: profile directory must not be readable by other"
          end

          parent = File.dirname(directory)
          break if parent == directory || !stat.owned?

          directory = parent
          immediate = false
        end
      end

      # Single parser pass that rejects load-time code execution vectors before
      # the data model is materialized: tags, excess aliases, duplicate keys.
      # Key/value position inside a mapping is tracked by alternating a flag;
      # containers and aliases also consume a slot in the enclosing mapping.
      def self.scan_yaml!(text, path)
        aliases = 0
        max_aliases = MAX_ALIASES
        stack = [] # [:mapping, seen_keys, expecting_key] or [:sequence]
        check_tag = lambda do |tag|
          if tag && !tag.start_with?("tag:yaml.org,2002:")
            raise ValidationError, "#{path}: YAML tags are not allowed in profiles"
          end
        end
        note_slot = lambda do |key|
          frame = stack.last
          next unless frame && frame[0] == :mapping

          if frame[2]
            # YAML merge keys splice one mapping into another after parsing, which
            # would let an anchor introduce keys the duplicate scan never saw.
            if key == "<<"
              raise ValidationError, "#{path}: YAML merge keys are not allowed in profiles"
            end
            if key && frame[1].include?(key)
              raise ValidationError, "#{path}: duplicate key #{key.inspect}"
            end

            frame[1] << key if key
          end
          frame[2] = !frame[2]
        end
        push = lambda do |frame|
          if stack.length >= MAX_NESTING
            raise ValidationError, "#{path}: YAML nesting exceeds #{MAX_NESTING}"
          end

          stack << frame
        end
        handler = Class.new(Psych::Handler) do
          define_method(:scalar) do |value, _anchor, tag, _plain, _quoted, _style|
            check_tag.call(tag)
            note_slot.call(value)
          end

          define_method(:alias) do |_anchor|
            aliases += 1
            if aliases > max_aliases
              raise ValidationError, "#{path}: too many YAML aliases (limit #{max_aliases})"
            end

            note_slot.call(nil)
          end

          define_method(:start_mapping) do |_anchor, tag, _implicit, _style|
            check_tag.call(tag)
            note_slot.call(nil)
            push.call([:mapping, [], true])
          end

          define_method(:end_mapping) { stack.pop }

          define_method(:start_sequence) do |_anchor, tag, _implicit, _style|
            check_tag.call(tag)
            note_slot.call(nil)
            push.call([:sequence])
          end

          define_method(:end_sequence) { stack.pop }
        end
        Psych::Parser.new(handler.new).parse(text)
      rescue Psych::SyntaxError => error
        raise ValidationError, "#{path}: invalid YAML: #{error.message}"
      end

      def self.safe_parse(text, path)
        Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
      rescue Psych::Exception => error
        raise ValidationError, "#{path}: invalid YAML: #{error.message}"
      end

      def self.normalize_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), normalized|
            normalized[String(key)] = normalize_keys(entry)
          end
        when Array
          value.map { |entry| normalize_keys(entry) }
        else
          value
        end
      end

      def self.validate_schema!(hash, path)
        unknown = hash.keys - TOP_LEVEL_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown sections #{unknown.sort.inspect}"
        end

        profile = required_hash(hash, "profile", path)
        version = profile["schema_version"]
        unless version.is_a?(Integer)
          raise ValidationError, "#{path}: profile.schema_version must be an integer"
        end
        if version > SCHEMA_VERSION
          raise ValidationError,
                "#{path}: profile schema version #{version} is newer than supported #{SCHEMA_VERSION}"
        end
        unless version == SCHEMA_VERSION
          raise ValidationError, "#{path}: no migration registered from schema version #{version}"
        end

        unknown_profile = profile.keys - PROFILE_KEYS
        unless unknown_profile.empty?
          raise ValidationError, "#{path}: unknown profile fields #{unknown_profile.sort.inspect}"
        end

        validate_strings!(hash, path)
        validate_profile_fields!(profile, path)
        validate_roots!(hash, profile, path)
        validate_model_roles!(hash, path)
        validate_budgets!(hash, path)
        validate_checks!(hash, path)
        tools = validate_tools!(hash, path)
        validate_policy!(hash, tools, path)
        hash
      end

      def self.required_hash(hash, key, path)
        value = hash[key]
        raise ValidationError, "#{path}: missing required section #{key.inspect}" unless value.is_a?(Hash)

        value
      end

      def self.validate_strings!(value, path, key_path = [])
        case value
        when Hash
          value.each do |key, entry|
            SECRET_KEY_DENYLIST.each do |denied|
              next unless key == denied

              raise ValidationError, "#{path}: key #{denied.inspect} is not allowed in profiles"
            end
            validate_strings!(entry, path, key_path + [key])
          end
        when Array
          value.each { |entry| validate_strings!(entry, path, key_path) }
        when String
          if INTERPOLATION_PATTERN.match?(value)
            raise ValidationError,
                  "#{path}: interpolation is not allowed (at #{key_path.join(".").inspect})"
          end
          if SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
            raise ValidationError, "#{path}: embedded secret material is not allowed"
          end
          if ENTROPY_PATTERN.match?(value) &&
             !ENTROPY_EXEMPT_KEYS.include?(key_path.last.to_s)
            raise ValidationError, "#{path}: high-entropy value rejected as candidate secret"
          end
        end
      end

      def self.validate_profile_fields!(profile, path)
        id = profile["profile_id"]
        unless id.is_a?(String) && PROFILE_ID_PATTERN.match?(id)
          raise ValidationError, "#{path}: profile.profile_id must match #{PROFILE_ID_PATTERN.inspect}"
        end
        version = profile["profile_version"]
        unless version.is_a?(String) && PROFILE_VERSION_PATTERN.match?(version)
          raise ValidationError,
                "#{path}: profile.profile_version must match #{PROFILE_VERSION_PATTERN.inspect}"
        end
        root = profile["canonical_root"]
        validate_root!(root, path, "profile.canonical_root")
        description = profile["description"]
        if description && (!description.is_a?(String) || description.bytesize > 1024)
          raise ValidationError, "#{path}: profile.description must be a string of at most 1024 bytes"
        end
      end

      def self.validate_root!(root, path, field)
        unless root.is_a?(String) && !root.empty? && root.start_with?(File::SEPARATOR) &&
               root.bytesize <= 4096 && !root.include?("\0")
          raise ValidationError, "#{path}: #{field} must be an absolute path"
        end
        if TIMEZONE_WORDS.include?(root.downcase)
          raise ValidationError, "#{path}: #{field} must not be an implicit host reference"
        end

        expanded = File.expand_path(root)
        if File.lstat(expanded).symlink?
          raise ValidationError, "#{path}: #{field} must not end in a symlink"
        end
        unless File.directory?(expanded)
          raise ValidationError, "#{path}: #{field} must be an existing directory"
        end
      rescue SystemCallError
        raise ValidationError, "#{path}: #{field} is unavailable"
      end

      def self.validate_roots!(hash, profile, path)
        roots = required_hash(hash, "roots", path)
        unknown = roots.keys - ROOTS_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown roots fields #{unknown.sort.inspect}"
        end

        workspace = roots["workspace"]
        validate_root!(workspace, path, "roots.workspace")
        unless File.expand_path(workspace) == File.expand_path(profile.fetch("canonical_root"))
          raise ValidationError,
                "#{path}: roots.workspace must equal profile.canonical_root in schema v1"
        end
      end

      def self.validate_model_roles!(hash, path)
        roles = hash["model_roles"] || {}
        raise ValidationError, "#{path}: model_roles must be a mapping" unless roles.is_a?(Hash)

        roles.each do |name, role|
          unless name.is_a?(String) && PROFILE_ID_PATTERN.match?(name)
            raise ValidationError, "#{path}: invalid model role name #{name.inspect}"
          end
          raise ValidationError, "#{path}: model role #{name.inspect} must be a mapping" unless role.is_a?(Hash)

          unknown = role.keys - MODEL_ROLE_KEYS
          unless unknown.empty?
            raise ValidationError, "#{path}: unknown model role fields #{unknown.sort.inspect}"
          end
          provider = role["provider"]
          unless provider.is_a?(String) &&
                 (KNOWN_PROVIDERS.include?(provider) || provider == "assume_model_exists")
            raise ValidationError, "#{path}: unknown provider #{provider.inspect} for role #{name.inspect}"
          end
          model = role["model"]
          unless model.is_a?(String) && !model.empty? && model.bytesize <= 256
            raise ValidationError, "#{path}: invalid model identifier for role #{name.inspect}"
          end
          validate_credential_ref!(role["credential_ref"], name, path) if role.key?("credential_ref")
        end
      end

      def self.validate_credential_ref!(ref, role, path)
        raise ValidationError, "#{path}: credential_ref for #{role.inspect} must be a mapping" unless ref.is_a?(Hash)

        unknown = ref.keys - CREDENTIAL_REF_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown credential_ref fields #{unknown.sort.inspect}"
        end
        unless ref["kind"] == "env"
          raise ValidationError, "#{path}: credential_ref kind must be \"env\" for role #{role.inspect}"
        end
        unless ref["name"].is_a?(String) && CREDENTIAL_REF_PATTERN.match?(ref["name"])
          raise ValidationError,
                "#{path}: credential_ref name for role #{role.inspect} must match " \
                "#{CREDENTIAL_REF_PATTERN.inspect}"
        end
      end

      def self.validate_budgets!(hash, path)
        budgets = hash["budgets"] || {}
        raise ValidationError, "#{path}: budgets must be a mapping" unless budgets.is_a?(Hash)

        unknown = budgets.keys - BUDGET_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown budget fields #{unknown.sort.inspect}"
        end
        budgets.each do |key, value|
          unless value.is_a?(Numeric) && value.finite? && !value.negative?
            raise ValidationError, "#{path}: budgets.#{key} must be a non-negative finite number"
          end
        end
      end

      def self.validate_checks!(hash, path)
        checks = hash["checks"] || {}
        raise ValidationError, "#{path}: checks must be a mapping" unless checks.is_a?(Hash)

        checks.each do |name, check|
          unless name.is_a?(String) && PROFILE_ID_PATTERN.match?(name)
            raise ValidationError, "#{path}: invalid check name #{name.inspect}"
          end
          raise ValidationError, "#{path}: check #{name.inspect} must be a mapping" unless check.is_a?(Hash)

          unknown = check.keys - CHECK_KEYS
          unless unknown.empty?
            raise ValidationError, "#{path}: unknown check fields #{unknown.sort.inspect}"
          end
          argv = check["argv"]
          unless argv.is_a?(Array) && !argv.empty? && argv.all? { |entry| entry.is_a?(String) && !entry.empty? }
            raise ValidationError, "#{path}: check #{name.inspect} argv must be a non-empty string array"
          end
          argv.each do |element|
            if element.include?("\0")
              raise ValidationError, "#{path}: check #{name.inspect} argv contains a NUL byte"
            end
            if CONTROL_CHARACTER_PATTERN.match?(element)
              raise ValidationError,
                    "#{path}: check #{name.inspect} argv contains a control character"
            end
            if element.bytesize > 4096
              raise ValidationError,
                    "#{path}: check #{name.inspect} argv element exceeds 4096 bytes"
            end
            if SHELL_METACHARACTER_PATTERN.match?(element)
              raise ValidationError,
                    "#{path}: check #{name.inspect} argv element #{element.inspect} " \
                    "contains shell metacharacters"
            end
          end
          validate_argv0!(argv.first, name, path)
          unless SAFETIES.include?(check["safety"])
            raise ValidationError, "#{path}: check #{name.inspect} safety must be one of #{SAFETIES.inspect}"
          end
        end
      end

      # argv[0] names the program that will actually run. A shell, an interpreter
      # that takes inline source, or a wrapper that re-executes another argv turns
      # the rest of argv into a program, which is exactly the injection the plan
      # forbids. Leading dashes are rejected so argv[0] cannot be smuggled as an
      # option to a downstream launcher.
      def self.validate_argv0!(program, name, path)
        unless program.is_a?(String) && !program.empty?
          raise ValidationError, "#{path}: check #{name.inspect} argv[0] must be a program name"
        end
        if program.start_with?("-")
          raise ValidationError,
                "#{path}: check #{name.inspect} argv[0] #{program.inspect} must not start with '-'"
        end
        if program.end_with?(File::SEPARATOR)
          raise ValidationError,
                "#{path}: check #{name.inspect} argv[0] #{program.inspect} must not be a directory"
        end

        basename = File.basename(program).downcase.sub(/\.(exe|bat|cmd|com)\z/, "")
        return unless ARGV0_DENYLIST.include?(basename)

        raise ValidationError,
              "#{path}: check #{name.inspect} argv[0] #{program.inspect} is a shell or " \
              "interpreter wrapper; a profile check names a program, not a command string"
      end

      def self.validate_tools!(hash, path)
        tools = required_hash(hash, "tools", path)
        unknown = tools.keys - TOOLS_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown tools fields #{unknown.sort.inspect}"
        end

        allowed = tools["allowed"]
        unless allowed.is_a?(Array) && !allowed.empty? &&
               allowed.all? { |name| name.is_a?(String) && KNOWN_TOOLS.include?(name) } &&
               allowed.uniq == allowed
          raise ValidationError, "#{path}: tools.allowed must be distinct known tool names"
        end
        required = tools["approval_required"] || []
        unless required.is_a?(Array) &&
               required.all? { |name| name.is_a?(String) && allowed.include?(name) } &&
               required.uniq == required
          raise ValidationError, "#{path}: tools.approval_required must be a subset of tools.allowed"
        end

        {"allowed" => allowed, "approval_required" => required}
      end

      def self.validate_policy!(hash, tools, path)
        policy = required_hash(hash, "policy", path)
        unknown = policy.keys - POLICY_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown policy fields #{unknown.sort.inspect}"
        end
        unless policy["allow_changes"] == true || policy["allow_changes"] == false
          raise ValidationError, "#{path}: policy.allow_changes must be true or false"
        end
        if policy["allow_changes"] == false
          action = tools.fetch("allowed") & %w[apply_patch create_file run_check]
          unless action.empty?
            raise ValidationError,
                  "#{path}: policy.allow_changes is false but action tools are allowed"
          end
        end
        unless SAFETIES.include?(policy["default_check_safety"])
          raise ValidationError, "#{path}: policy.default_check_safety must be one of #{SAFETIES.inspect}"
        end
        unless policy["graph_version"] == Tamoz::Agent::Session::GRAPH_VERSION
          raise ValidationError,
                "#{path}: policy.graph_version must equal #{Tamoz::Agent::Session::GRAPH_VERSION.inspect}"
        end
        behavior = policy["behavior_version"]
        unless behavior.is_a?(String) && !behavior.empty? && behavior.bytesize <= 64
          raise ValidationError, "#{path}: policy.behavior_version must be a string of at most 64 bytes"
        end
        digest = policy["tool_catalog_digest"]
        unless digest.is_a?(String) && DIGEST_PATTERN.match?(digest)
          raise ValidationError, "#{path}: policy.tool_catalog_digest must be a sha256: digest"
        end
      end

      def self.canonical_digest(hash)
        "sha256:#{Digest::SHA256.hexdigest(
          DIGEST_DOMAIN + JSON.generate(Deliberation.canonical(hash))
        )}"
      end

      def self.deep_freeze(value)
        case value
        when Hash
          value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
        when Array
          value.each { |entry| deep_freeze(entry) }
        end

        value.freeze
      end

      def self.build_fields(hash, digest:, suggestion:, pinned: false)
        profile = hash.fetch("profile")
        tools = hash.fetch("tools")
        checks = (hash["checks"] || {}).transform_values do |check|
          {"argv" => check.fetch("argv"), "safety" => check.fetch("safety")}
        end
        new_fields = {
          profile_id: profile.fetch("profile_id"),
          profile_version: profile.fetch("profile_version"),
          canonical_root: File.realpath(File.expand_path(profile.fetch("canonical_root"))),
          description: profile["description"],
          model_roles: hash["model_roles"] || {},
          budgets: hash["budgets"] || {},
          checks:,
          tools_allowed: tools.fetch("allowed"),
          tools_approval_required: tools["approval_required"] || [],
          policy: hash.fetch("policy"),
          canonical_digest: digest,
          suggestion:,
          pinned:
        }
        Fields.new(**new_fields)
      end

      # Operator adoption registry (§3.6): which profile digests the operator has
      # explicitly activated. Lives outside profile files and any repository,
      # mode 0600, and never participates in any canonical digest.
      class AdoptionRegistry
        REGISTRY_SCHEMA_VERSION = 1

        attr_reader :path

        def initialize(path: nil, env: ENV)
          @path = path || Profile.adoption_path(env:)
          freeze
        end

        def activated?(profile_id, digest)
          digests(profile_id).include?(digest)
        end

        def digests(profile_id)
          document.fetch("activated").fetch(profile_id, [])
        end

        def activate(profile_id, digest)
          Profile.verify_permissions!(@path) if File.exist?(@path)
          current = File.exist?(@path) ? document : empty_document
          activated = current.fetch("activated")
          list = activated.fetch(profile_id, [])
          return if list.include?(digest)

          updated = current.merge("activated" => activated.merge(profile_id => list + [digest]))
          directory = File.dirname(@path)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
          File.write(@path, Psych.dump(updated))
          File.chmod(0o600, @path)
        end

        private

        def empty_document
          {"schema_version" => REGISTRY_SCHEMA_VERSION, "activated" => {}}
        end

        def document
          unless File.exist?(@path)
            return empty_document
          end

          Profile.verify_permissions!(@path)
          data = Psych.safe_load(
            File.binread(@path), permitted_classes: [], permitted_symbols: [], aliases: false
          )
          unless data.is_a?(Hash) && data["schema_version"] == REGISTRY_SCHEMA_VERSION &&
                 data["activated"].is_a?(Hash) &&
                 data["activated"].all? do |id, entries|
                   id.is_a?(String) && entries.is_a?(Array) &&
                     entries.all? { |entry| entry.is_a?(String) && DIGEST_PATTERN.match?(entry) }
                 end
            raise AdoptionError, "#{@path}: adoption registry is invalid"
          end

          Profile.normalize_keys(data)
        rescue Psych::Exception => error
          raise AdoptionError, "#{@path}: adoption registry is unreadable: #{error.message}"
        end
      end

      # One operator-recorded candidate profile transition for a thread (§5.4).
      # A candidate is not authority: it only permits the *next turn boundary*
      # of that exact thread to move from `from_digest` to `to_digest`.
      Transition = Data.define(:thread_id, :profile_id, :from_digest, :to_digest, :reason) do
        def initialize(**members)
          super(**members.transform_values { |value| String(value).dup.freeze })
        end

        def to_h_document
          {
            "profile_id" => profile_id,
            "from_digest" => from_digest,
            "to_digest" => to_digest,
            "reason" => reason
          }
        end
      end

      # Operator-side candidate transition registry (§5.4/§6.5). Lives beside the
      # adoption registry, outside any profile file and any repository, mode 0600,
      # and participates in no digest. Recording a candidate never touches session
      # state, so in-flight authority cannot be mutated by writing here.
      class TransitionRegistry
        REGISTRY_SCHEMA_VERSION = 1
        REASON_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
        THREAD_PATTERN = /\A[A-Za-z0-9_\-.]{1,64}\z/

        attr_reader :path

        def initialize(path: nil, env: ENV)
          @path = path || Profile.transitions_path(env:)
          freeze
        end

        def candidates(thread_id)
          document.fetch("transitions").fetch(String(thread_id), []).map do |entry|
            Transition.new(
              thread_id: String(thread_id),
              profile_id: entry.fetch("profile_id"),
              from_digest: entry.fetch("from_digest"),
              to_digest: entry.fetch("to_digest"),
              reason: entry.fetch("reason")
            )
          end
        end

        def candidate?(thread_id, profile_id:, from:, to:)
          candidates(thread_id).any? do |entry|
            entry.profile_id == profile_id && entry.from_digest == from && entry.to_digest == to
          end
        end

        def record(transition)
          validate!(transition)
          Profile.verify_permissions!(@path) if File.exist?(@path)
          current = File.exist?(@path) ? document : empty_document
          transitions = current.fetch("transitions")
          list = transitions.fetch(transition.thread_id, [])
          entry = transition.to_h_document
          return transition if list.include?(entry)

          updated = current.merge(
            "transitions" => transitions.merge(transition.thread_id => list + [entry])
          )
          directory = File.dirname(@path)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
          File.write(@path, Psych.dump(updated))
          File.chmod(0o600, @path)
          transition
        end

        private

        def validate!(transition)
          unless THREAD_PATTERN.match?(transition.thread_id)
            raise AdoptionError, "invalid thread id #{transition.thread_id.inspect}"
          end
          unless PROFILE_ID_PATTERN.match?(transition.profile_id)
            raise AdoptionError, "invalid profile id #{transition.profile_id.inspect}"
          end
          unless REASON_PATTERN.match?(transition.reason)
            raise AdoptionError, "invalid transition reason #{transition.reason.inspect}"
          end
          [transition.from_digest, transition.to_digest].each do |digest|
            next if DIGEST_PATTERN.match?(digest)

            raise AdoptionError, "invalid transition digest #{digest.inspect}"
          end
        end

        def empty_document
          {"schema_version" => REGISTRY_SCHEMA_VERSION, "transitions" => {}}
        end

        def document
          return empty_document unless File.exist?(@path)

          Profile.verify_permissions!(@path)
          data = Psych.safe_load(
            File.binread(@path), permitted_classes: [], permitted_symbols: [], aliases: false
          )
          unless valid_document?(data)
            raise AdoptionError, "#{@path}: transition registry is invalid"
          end

          Profile.normalize_keys(data)
        rescue Psych::Exception => error
          raise AdoptionError, "#{@path}: transition registry is unreadable: #{error.message}"
        end

        def valid_document?(data)
          return false unless data.is_a?(Hash)
          return false unless data["schema_version"] == REGISTRY_SCHEMA_VERSION
          return false unless data["transitions"].is_a?(Hash)

          data["transitions"].all? do |thread_id, entries|
            thread_id.is_a?(String) && THREAD_PATTERN.match?(thread_id) &&
              entries.is_a?(Array) && entries.all? { |entry| valid_entry?(entry) }
          end
        end

        def valid_entry?(entry)
          entry.is_a?(Hash) &&
            (entry.keys.sort == %w[from_digest profile_id reason to_digest]) &&
            PROFILE_ID_PATTERN.match?(entry["profile_id"].to_s) &&
            REASON_PATTERN.match?(entry["reason"].to_s) &&
            DIGEST_PATTERN.match?(entry["from_digest"].to_s) &&
            DIGEST_PATTERN.match?(entry["to_digest"].to_s)
        end
      end
    end
  end
end

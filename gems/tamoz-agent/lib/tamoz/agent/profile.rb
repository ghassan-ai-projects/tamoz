# frozen_string_literal: true

require "digest"
require "fileutils"
require "forwardable"
require "json"
require "pathname"
require "psych"
require "time"

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
      # P8-E: opening a FIFO read-only blocks until a writer appears, so a profile
      # path pointing at a named pipe would hang the loader forever instead of
      # failing. O_NONBLOCK makes the open return immediately; the regular-file
      # check on the resulting descriptor then rejects it with a typed error.
      NONBLOCK = File::Constants.const_defined?(:NONBLOCK) ? File::Constants::NONBLOCK : 0
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

      TOP_LEVEL_KEYS = %w[profile roots model_roles budgets checks tools policy egress unattended].freeze
      # What may run with NOBODY WATCHING. This is deliberately a separate axis
      # from `tools`: `tools.allowed` says what the agent can ever do on this
      # project, `unattended` says what a worker may do without asking first.
      # A tool can be allowed and still require a human every time.
      UNATTENDED_KEYS = %w[read_only reconcilable approval_required forbidden].freeze
      PROFILE_KEYS = %w[schema_version profile_id profile_version canonical_root description].freeze
      ROOTS_KEYS = %w[workspace].freeze
      MODEL_ROLE_KEYS = %w[provider model credential_ref].freeze
      CREDENTIAL_REF_KEYS = %w[kind name].freeze
      BUDGET_KEYS = %w[cost_usd input_tokens output_tokens wall_clock_seconds steps].freeze
      CHECK_KEYS = %w[argv safety].freeze
      TOOLS_KEYS = %w[allowed approval_required].freeze
      POLICY_KEYS = %w[
        allow_changes default_check_safety graph_version behavior_version tool_catalog_digest
        unattended_catalog_digest
      ].freeze
      # P17 §3: the operator-declared egress policy for governed network
      # capabilities (the websearch server). Exact FQDNs only in v1 — no
      # wildcards, no IP literals, no ports, https only. `credential_refs`
      # carries NAMES only; values never materialize in a profile (invariant
      # 24). The whole section is part of the profile's canonical digest, so any
      # edit is a new profile version that the session-authority machinery
      # re-pins (P8 §5.4 / P17 correction 5).
      EGRESS_KEYS = %w[
        allowlisted_hosts schemes deny_private_ranges max_request_bytes
        max_response_bytes connect_timeout_s redirect_max_hops circuit credential_refs
      ].freeze
      EGRESS_CIRCUIT_KEYS = %w[threshold scope_type budget_breach].freeze
      EGRESS_SCOPE_TYPE = "egress"
      EGRESS_SCHEMES = ["https"].freeze
      EGRESS_MAX_REQUEST_BYTES = 8192
      EGRESS_MAX_RESPONSE_BYTES = 64 * 1024
      EGRESS_MAX_CONNECT_TIMEOUT_S = 300
      EGRESS_MAX_REDIRECT_HOPS = 10
      EGRESS_MAX_CIRCUIT_THRESHOLD = 10
      # A bare IP-shaped host in any spelling defeats the "exact FQDN" rule if
      # only the common spellings are checked, so the admission rule rejects
      # dotted-quad, bare decimal, hex, and octal forms outright; the per-hop
      # adapter check re-runs the full neutralization at every connection and
      # redirect target (P17 §4).
      EGRESS_IPV4_PATTERN = /\A(?:\d{1,3}\.){3}\d{1,3}\z/
      EGRESS_IPV6_PATTERN = /\A[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[0-9A-Za-z.]+)?\z/
      EGRESS_NUMERIC_IP_PATTERN = /\A(?:\d+|0[xX][0-9A-Fa-f]+|0[0-7]+)\z/
      EGRESS_HOST_LABEL_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
      # Credential-shaped NAME in a non-ref egress list. `TAMOZ_SEARCH_API_TOKEN`
      # is a credential-ref name and is admitted in `credential_refs` only; the
      # same shape in `allowlisted_hosts` or anywhere else is a mistake that
      # would quietly smuggle a secret-bearing name into policy, so it is a
      # typed rejection (invariant 24).
      EGRESS_CREDENTIAL_NAME_PATTERN = /(?:\A|_)(?:
        API_?KEYS? | ACCESS_?KEYS? | SECRET_?KEYS? | PRIVATE_?KEYS? | SESSION_?KEYS? |
        TOKENS? | SECRETS? | PASSWORD | PASSWD | CREDENTIALS? | PASSPHRASE
      )(?:\z|_)/x

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
      ENTROPY_EXEMPT_KEYS = %w[
        canonical_root workspace tool_catalog_digest unattended_catalog_digest
      ].freeze
      TIMEZONE_WORDS = %w[local system host].freeze

      ProfileError = Class.new(Tamoz::Agent::Error)
      PermissionError = Class.new(ProfileError)
      ValidationError = Class.new(ProfileError)
      AdoptionError = Class.new(ProfileError)

      Fields = Data.define(
        :profile_id, :profile_version, :canonical_root, :description,
        :model_roles, :budgets, :checks, :tools_allowed, :tools_approval_required,
        :policy, :canonical_digest, :suggestion, :pinned, :egress, :unattended
      ) do
        def initialize(pinned: false, **members)
          members[:egress] = nil unless members.key?(:egress)
          members[:unattended] = nil unless members.key?(:unattended)
          super(pinned:, **Profile.deep_freeze(members))
        end

        def allow_changes? = policy.fetch("allow_changes")

        # The tools a worker may use with nobody watching. Absent section means
        # NOTHING is preauthorized — a profile that has never thought about
        # unattended execution does not accidentally authorize it.
        #
        # `forbidden` is subtracted last so it cannot be overridden.
        def unattended_preauthorized
          return [] if unattended.nil?

          preauthorized = Array(unattended["read_only"]) + Array(unattended["reconcilable"])
          (preauthorized - Array(unattended["forbidden"])).uniq.freeze
        end

        # Everything else the profile allows: possible, but only with a human.
        def unattended_requires_approval
          (tools_allowed - unattended_preauthorized).uniq.freeze
        end
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
                     :suggestion, :pinned, :allow_changes?, :high_risk?, :egress,
                     :unattended, :unattended_preauthorized, :unattended_requires_approval

      # P8-B §5.1/§5.4: the exact capability authority a durable session was
      # started under, in a form that can be replayed from the checkpoint alone.
      # Credential references are recorded by NAME only (DR-5 RC4): the checkpoint
      # never carries a credential VALUE (invariant 24), and replay resolves the
      # IDENTICAL env key the original ask used instead of silently falling back to
      # the generic provider key. The name is an env-var identifier, which
      # invariant 24 permits; nothing here can widen authority because
      # reconstruction re-runs the same validators (invariant 35).
      def authority_snapshot
        snapshot = {
          "profile_id" => profile_id,
          "profile_version" => profile_version,
          "canonical_digest" => canonical_digest,
          "canonical_root" => canonical_root,
          "model_roles" => model_roles.transform_values do |role|
            ref = role["credential_ref"]
            if ref
              role.merge("credential_ref" => {"kind" => "env", "name" => ref.fetch("name")})
            else
              role
            end
          end,
          "checks" => checks,
          "tools" => {
            "allowed" => tools_allowed,
            "approval_required" => tools_approval_required
          },
          "policy" => policy
        }
        # P17 (correction 5): the operator-declared egress policy joins the
        # pinned authority, so a resumed checkpoint re-pins the exact egress
        # declaration. `nil` (no egress section) is the pre-P17 sentinel and is
        # simply omitted — `from_authority` treats absence as "no egress".
        snapshot["egress"] = egress if egress
        Profile.deep_freeze(snapshot)
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

      # The exact bytes that produced a validated document, returned alongside it.
      # `tamoz profile import` installs these rather than re-reading the source: a
      # second read of a repository-controlled path can return different bytes than
      # the ones whose digest the operator just confirmed.
      Source = Data.define(:document, :bytes)

      def self.preview_source(path, suggestion: false)
        expanded = File.expand_path(File.path(path))
        captured = nil
        document = load_document(expanded, suggestion:) { |bytes| captured = bytes }
        Source.new(document:, bytes: captured)
      end

      AUTHORITY_KEYS = %w[
        profile_id profile_version canonical_digest canonical_root model_roles checks tools policy egress
      ].freeze

      # P8-B §5.4/§5.5: rebuild the authority a session was pinned to from its
      # own checkpoint. The snapshot is treated as untrusted input and re-runs
      # every validator, so a corrupted or tampered checkpoint can only narrow
      # or fail, never widen. Model roles may carry a credential reference NAME
      # (DR-5 RC4), validated by the same `validate_model_roles!` gate a profile
      # file passes; replay resolves that env key, never a value stored here.
      def self.from_authority(snapshot, source: "<pinned session authority>")
        unless snapshot.is_a?(Hash)
          raise ValidationError, "#{source}: pinned profile authority must be a mapping"
        end

        hash = normalize_keys(snapshot)
        unknown = hash.keys - AUTHORITY_KEYS
        unless unknown.empty?
          raise ValidationError, "#{source}: unknown pinned authority fields #{unknown.sort.inspect}"
        end
        missing = AUTHORITY_KEYS - hash.keys - %w[model_roles checks egress]
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
        # P17 (correction 5): the pinned egress declaration is replayed through
        # the same fail-closed validator a profile file passes, so a tampered
        # checkpoint can only narrow or fail, never widen.
        synthetic["egress"] = hash["egress"] if hash.key?("egress")
        validate_profile_fields!(synthetic.fetch("profile"), source)
        validate_roots!(synthetic, synthetic.fetch("profile"), source)
        validate_model_roles!(synthetic, source)
        validate_checks!(synthetic, source)
        tools = validate_tools!(synthetic, source)
        validate_policy!(synthetic, tools, source)
        validate_egress!(synthetic, source)
        new(build_fields(synthetic, digest:, suggestion: false, pinned: true))
      end

      # P8-E: macOS and Windows resolve `.Tamoz/suggested-profile.yaml` to the very
      # same directory entry as `.tamoz/`, so an exact-case component match let a
      # repository-supplied suggestion be addressed as authority simply by changing
      # the case of the path. The comparison is case-folded, which over-rejects on a
      # case-sensitive filesystem and therefore fails closed on every platform.
      def self.suggestion_path?(expanded_path)
        Pathname.new(expanded_path).each_filename.any? do |component|
          component.downcase == SUGGESTION_DIRECTORY
        end
      end

      # P8-E: a profile stored inside the very root it grants authority over is
      # repository-controlled content. Editing the repository would then edit the
      # authority; the digest check makes that fail closed rather than silently
      # widen, but §3.1 requires operator-owned storage outside the project, so the
      # arrangement is refused outright. Suggestions are exempt: being inside the
      # repository is exactly what makes them evidence.
      def self.verify_outside_root!(expanded_path, canonical_root, path)
        directory = File.dirname(expanded_path)
        loop do
          if File.identical?(directory, canonical_root)
            raise ValidationError,
                  "#{path}: profile must not live inside its own canonical_root " \
                  "#{canonical_root.inspect}; operator profiles live outside the project"
          end

          parent = File.dirname(directory)
          break if parent == directory

          directory = parent
        end
      rescue SystemCallError
        nil
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
        yield bytes if block_given?
        scan_yaml!(bytes, expanded_path)
        data = safe_parse(bytes, expanded_path)
        unless data.is_a?(Hash)
          raise ValidationError, "#{expanded_path}: profile must be a YAML mapping"
        end

        hash = normalize_keys(data)
        hash.delete("adoption")
        validate_schema!(hash, expanded_path)
        digest = canonical_digest(hash)
        fields = build_fields(hash, digest:, suggestion:)
        verify_outside_root!(expanded_path, fields.canonical_root, expanded_path) unless suggestion
        new(fields)
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
        handle = File.open(path, File::RDONLY | NOFOLLOW | NONBLOCK)
        begin
          unless handle.stat.file?
            raise PermissionError, "#{path}: profile must be a regular file"
          end

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
        documents = 0
        max_aliases = MAX_ALIASES
        stack = [] # [:mapping, seen_keys, expecting_key] or [:sequence]
        check_tag = lambda do |tag|
          if tag && !tag.start_with?("tag:yaml.org,2002:")
            raise ValidationError, "#{path}: YAML tags are not allowed in profiles"
          end
        end
        # A collection opened in key position is a YAML complex key. Nothing in the
        # schema has one, and it defeats the literal-key duplicate scan, so it is a
        # typed rejection rather than something the key allowlist happens to catch.
        reject_complex_key = lambda do
          frame = stack.last
          next unless frame && frame[0] == :mapping && frame[2]

          raise ValidationError, "#{path}: YAML complex (collection) keys are not allowed"
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

          define_method(:start_document) do |_version, _tags, _implicit|
            documents += 1
            if documents > 1
              raise ValidationError,
                    "#{path}: a profile is exactly one YAML document; trailing documents " \
                    "are silently ignored by the loader and are therefore refused"
            end
          end

          define_method(:alias) do |_anchor|
            aliases += 1
            if aliases > max_aliases
              raise ValidationError, "#{path}: too many YAML aliases (limit #{max_aliases})"
            end

            # P8-E: an alias in *key* position resolves to whatever the anchor holds,
            # so the duplicate-key and merge-key scans below never see the real key.
            # `policy: {allow_changes: false, *k: true}` with `&k "allow_changes"`
            # read as a denial but loaded as a grant. A key is a literal scalar.
            frame = stack.last
            if frame && frame[0] == :mapping && frame[2]
              raise ValidationError,
                    "#{path}: YAML aliases are not allowed in mapping key position"
            end

            note_slot.call(nil)
          end

          define_method(:start_mapping) do |_anchor, tag, _implicit, _style|
            check_tag.call(tag)
            reject_complex_key.call
            note_slot.call(nil)
            push.call([:mapping, [], true])
          end

          define_method(:end_mapping) { stack.pop }

          define_method(:start_sequence) do |_anchor, tag, _implicit, _style|
            check_tag.call(tag)
            reject_complex_key.call
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
        validate_unattended!(hash, path)
        validate_profile_fields!(profile, path)
        validate_roots!(hash, profile, path)
        validate_model_roles!(hash, path)
        validate_budgets!(hash, path)
        validate_checks!(hash, path)
        tools = validate_tools!(hash, path)
        validate_policy!(hash, tools, path)
        validate_egress!(hash, path)
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
        # DR-5 RC3: "legacy" is the session-record sentinel for sessions that
        # predate trusted profiles (SessionRecords::LEGACY_PROFILE_ID). A real
        # profile named "legacy" would be misclassified by the shipped cli.rb
        # sentinel guard and silently destroy the sentinel semantics, so the id
        # is reserved and refused here, at load.
        if id == SessionRecords::LEGACY_PROFILE_ID
          raise ValidationError,
                "#{path}: profile.profile_id \"legacy\" is reserved for sessions that " \
                "predate trusted profiles; choose another profile id"
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
        # P8-E: a configured check runs with the *untrusted workspace* as its working
        # directory, so a relative argv[0] that contains a separator ("bin/check",
        # "./tools/run") names a file the repository supplies. That is content
        # granting itself execution, which invariant 35 forbids. A bare program name
        # is resolved through PATH (which never contains the workspace) and an
        # absolute path names an operator-chosen program, so both remain allowed.
        if separator?(program) && !program.start_with?(File::SEPARATOR)
          raise ValidationError,
                "#{path}: check #{name.inspect} argv[0] #{program.inspect} is a relative path; " \
                "it would resolve inside the untrusted workspace. Use an absolute path or a " \
                "bare program name resolved through PATH"
        end

        basename = File.basename(program).downcase.sub(/\.(exe|bat|cmd|com)\z/, "")
        if [".", ".."].include?(basename)
          raise ValidationError,
                "#{path}: check #{name.inspect} argv[0] #{program.inspect} is not a program"
        end
        return unless ARGV0_DENYLIST.include?(basename)

        raise ValidationError,
              "#{path}: check #{name.inspect} argv[0] #{program.inspect} is a shell or " \
              "interpreter wrapper; a profile check names a program, not a command string"
      end

      # True when the value carries a path separator for this platform.
      def self.separator?(value)
        return true if value.include?(File::SEPARATOR)

        alternate = File::ALT_SEPARATOR
        !alternate.nil? && value.include?(alternate)
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

      # The unattended section names tools by RISK CLASS. Every name must be a
      # tool this profile allows: preauthorizing something the profile does not
      # permit is a contradiction, and silently ignoring it would let a profile
      # look more permissive than it is.
      #
      # `forbidden` wins over every other list. A tool named there can never run
      # unattended no matter what else claims it — a deny must not be defeatable
      # by adding the same name somewhere more permissive.
      def self.validate_unattended!(hash, path)
        section = hash["unattended"]
        return if section.nil?

        unless section.is_a?(Hash)
          raise ValidationError, "#{path}: unattended must be a mapping"
        end

        unknown = section.keys - UNATTENDED_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown unattended fields #{unknown.sort.inspect}"
        end

        allowed = hash.dig("tools", "allowed") || []
        UNATTENDED_KEYS.each do |key|
          names = section[key]
          next if names.nil?

          unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) } &&
                 names.uniq == names
            raise ValidationError, "#{path}: unattended.#{key} must be distinct tool names"
          end
          outside = names - allowed
          unless outside.empty?
            raise ValidationError,
                  "#{path}: unattended.#{key} names #{outside.sort.inspect}, which " \
                  "tools.allowed does not permit"
          end
        end
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
        unattended_digest = policy["unattended_catalog_digest"]
        if !unattended_digest.nil? && !DIGEST_PATTERN.match?(unattended_digest)
          raise ValidationError,
                "#{path}: policy.unattended_catalog_digest must be a sha256: digest"
        end
        digest = policy["tool_catalog_digest"]
        unless digest.is_a?(String) && DIGEST_PATTERN.match?(digest)
          raise ValidationError, "#{path}: policy.tool_catalog_digest must be a sha256: digest"
        end
      end

      # P17 §3: the operator-declared egress policy, validated fail-closed.
      # Absent (`nil`) is the pre-P17 state and means "no governed egress
      # declaration"; present means every field is exact and bounded. The
      # declaration is part of the canonical digest, so any edit is a new
      # profile version that the session-authority machinery re-pins.
      def self.validate_egress!(hash, path)
        egress = hash["egress"]
        return nil if egress.nil?

        unless egress.is_a?(Hash)
          raise ValidationError, "#{path}: egress must be a mapping"
        end

        unknown = egress.keys - EGRESS_KEYS
        unless unknown.empty?
          raise ValidationError, "#{path}: unknown egress fields #{unknown.sort.inspect}"
        end

        hosts = egress["allowlisted_hosts"]
        unless hosts.is_a?(Array) && !hosts.empty? &&
               hosts.all? { |host| host.is_a?(String) } && hosts.uniq == hosts
          raise ValidationError,
                "#{path}: egress.allowlisted_hosts must be a non-empty array of distinct strings"
        end
        hosts.each do |host|
          field = "egress.allowlisted_hosts entry #{host.inspect}"
          if EGRESS_CREDENTIAL_NAME_PATTERN.match?(host)
            raise ValidationError,
                  "#{path}: #{field} is credential-shaped; names belong in " \
                  "egress.credential_refs only (values never enter a profile)"
          end
          validate_egress_host!(host, path, field)
        end

        schemes = egress["schemes"]
        unless schemes == EGRESS_SCHEMES
          raise ValidationError, "#{path}: egress.schemes must be exactly #{EGRESS_SCHEMES.inspect} in v1"
        end

        deny = egress["deny_private_ranges"]
        unless deny == true || deny == false
          raise ValidationError, "#{path}: egress.deny_private_ranges must be true or false"
        end

        validate_egress_integer!(
          egress["max_request_bytes"], path, "egress.max_request_bytes",
          1, EGRESS_MAX_REQUEST_BYTES
        )
        validate_egress_integer!(
          egress["max_response_bytes"], path, "egress.max_response_bytes",
          1, EGRESS_MAX_RESPONSE_BYTES
        )
        timeout = egress["connect_timeout_s"]
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? &&
               timeout <= EGRESS_MAX_CONNECT_TIMEOUT_S
          raise ValidationError,
                "#{path}: egress.connect_timeout_s must be a positive finite number " \
                "of at most #{EGRESS_MAX_CONNECT_TIMEOUT_S}"
        end
        validate_egress_integer!(
          egress["redirect_max_hops"], path, "egress.redirect_max_hops",
          1, EGRESS_MAX_REDIRECT_HOPS
        )

        circuit = egress["circuit"]
        unless circuit.is_a?(Hash)
          raise ValidationError, "#{path}: egress.circuit must be a mapping"
        end
        unknown_circuit = circuit.keys - EGRESS_CIRCUIT_KEYS
        unless unknown_circuit.empty?
          raise ValidationError,
                "#{path}: unknown egress.circuit fields #{unknown_circuit.sort.inspect}"
        end
        unless circuit["scope_type"] == EGRESS_SCOPE_TYPE
          raise ValidationError,
                "#{path}: egress.circuit.scope_type must be #{EGRESS_SCOPE_TYPE.inspect}"
        end
        validate_egress_integer!(
          circuit["threshold"], path, "egress.circuit.threshold",
          1, EGRESS_MAX_CIRCUIT_THRESHOLD
        )
        budget_breach = circuit["budget_breach"]
        unless budget_breach == true || budget_breach == false
          raise ValidationError, "#{path}: egress.circuit.budget_breach must be true or false"
        end

        refs = egress["credential_refs"]
        unless refs.is_a?(Array) && refs.uniq == refs &&
               refs.all? { |name| name.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(name) }
          raise ValidationError,
                "#{path}: egress.credential_refs must be distinct names matching " \
                "#{CREDENTIAL_REF_PATTERN.inspect}; names only, values never enter a profile"
        end

        egress
      end

      # Exact absolute DNS FQDN: lowercase, at least two dot-separated labels,
      # no wildcard, no IP literal in any spelling, no scheme/port/path/
      # userinfo. v1 deliberately has no wildcards or IP-literal allowlisting;
      # the per-hop adapter check is the second layer (P17 §4).
      def self.validate_egress_host!(host, path, field)
        if host.bytesize > 253 || host.empty?
          raise ValidationError, "#{path}: #{field} must be an absolute DNS name of at most 253 bytes"
        end
        if host.include?("*")
          raise ValidationError, "#{path}: #{field} contains a wildcard; v1 allows exact FQDNs only"
        end
        if host.include?("/") || host.include?("@") || host.include?(":") || host.match?(/\s/)
          raise ValidationError,
                "#{path}: #{field} must be a bare hostname with no scheme, port, path, or userinfo"
        end
        unless host == host.downcase
          raise ValidationError, "#{path}: #{field} must be lowercase"
        end
        if EGRESS_IPV4_PATTERN.match?(host) || EGRESS_IPV6_PATTERN.match?(host) ||
           EGRESS_NUMERIC_IP_PATTERN.match?(host)
          raise ValidationError, "#{path}: #{field} is an IP literal; v1 allows exact FQDNs only"
        end
        labels = host.split(".")
        unless labels.length >= 2 && labels.none?(&:empty?) &&
               labels.all? { |label| label.bytesize <= 63 && EGRESS_HOST_LABEL_PATTERN.match?(label) }
          raise ValidationError, "#{path}: #{field} is not a valid absolute DNS name"
        end
        if labels.last.match?(/\A\d+\z/)
          raise ValidationError, "#{path}: #{field} must not end in a numeric label"
        end

        host
      end

      def self.validate_egress_integer!(value, path, field, minimum, maximum)
        unless value.is_a?(Integer) && value.between?(minimum, maximum)
          raise ValidationError,
                "#{path}: #{field} must be an integer between #{minimum} and #{maximum}"
        end

        value
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
          pinned:,
          egress: hash["egress"],
          unattended: hash["unattended"]
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
      # of that exact thread to move from `from_digest` to `to_digest`. DR-5 D2:
      # an entry is optionally marked consumed (`consumed_by` request id +
      # `consumed_at`) inside the registry's single flocked critical section; a
      # consumed entry is an audit record and never re-applies.
      Transition = Data.define(
        :thread_id, :profile_id, :from_digest, :to_digest, :reason, :consumed_by, :consumed_at
      ) do
        def initialize(**members)
          members = {consumed_by: nil, consumed_at: nil}.merge(members)
          normalized = members.transform_values do |value|
            value.nil? ? nil : String(value).dup.freeze
          end
          super(**normalized)
        end

        def consumed? = !consumed_by.nil?

        def to_h_document
          document = {
            "profile_id" => profile_id,
            "from_digest" => from_digest,
            "to_digest" => to_digest,
            "reason" => reason
          }
          if consumed?
            document["consumed_by"] = consumed_by
            document["consumed_at"] = consumed_at
          end
          document
        end
      end

      # Operator-side candidate transition registry (§5.4/§6.5). Lives beside the
      # adoption registry, outside any profile file and any repository, mode 0600,
      # and participates in no digest. Recording a candidate never touches session
      # state, so in-flight authority cannot be mutated by writing here.
      #
      # DR-5 D2 codec: schema_version 2 allows entries to carry `consumed_by` +
      # `consumed_at`; v1 documents (the exact 4-key entries) remain readable and
      # are never rewritten on read. Every writer — operator `record` and the
      # consuming boundary ask — does its full-file read-modify-write inside ONE
      # flocked critical section (`with_registry_lock`), so concurrent record and
      # consume cannot clobber each other's writes and the candidate is consumed
      # exactly once. flock releases on fd close, so a killed writer never leaves
      # a stale lock wedging the registry.
      class TransitionRegistry
        REGISTRY_SCHEMA_VERSION = 2
        LEGACY_REGISTRY_SCHEMA_VERSION = 1
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
              reason: entry.fetch("reason"),
              consumed_by: entry["consumed_by"],
              consumed_at: entry["consumed_at"]
            )
          end
        end

        # A consumed entry is an audit record: it can never re-apply, so it is
        # never a candidate again.
        def candidate?(thread_id, profile_id:, from:, to:)
          candidates(thread_id).any? do |entry|
            !entry.consumed? &&
              entry.profile_id == profile_id && entry.from_digest == from && entry.to_digest == to
          end
        end

        # DR-5 D2 RC8: candidates that can no longer apply for this thread — the
        # session is past `from_digest` and the current profile is past
        # `to_digest` — are surfaced at the boundary instead of sitting silently
        # inert. Consumed entries are excluded so the advisory never fires on
        # every subsequent ask for the thread's life; no pruning in v1 (audit).
        def dead_candidates(thread_id, stored_digest, loaded_digest)
          candidates(thread_id).select do |entry|
            !entry.consumed? &&
              entry.from_digest != stored_digest &&
              entry.to_digest != loaded_digest
          end
        end

        def record(transition)
          validate!(transition)
          with_registry_lock do
            current = File.exist?(@path) ? document : empty_document
            transitions = current.fetch("transitions")
            list = transitions.fetch(transition.thread_id, [])
            entry = transition.to_h_document
            return transition if list.include?(entry)

            updated = current.merge(
              "transitions" => transitions.merge(transition.thread_id => list + [entry])
            )
            write_document(updated)
            transition
          end
        end

        # DR-5 D2 RC2: ONE flocked check-and-mark RMW. Returns the consumed
        # Transition when this writer won the race, nil when the entry is absent
        # or already consumed (a lost race falls through to pinned replay — never
        # a typed terminal error). The decision is made on the CURRENT file bytes
        # inside the lock, so no stale before-image can be consumed (no TOCTOU).
        def consume_if_candidate!(thread_id, profile_id:, from:, to:, consumed_by:)
          raise ArgumentError, "consumed_by is required to consume a candidate" if consumed_by.to_s.empty?

          with_registry_lock do
            current = File.exist?(@path) ? document : empty_document
            transitions = current.fetch("transitions")
            list = transitions.fetch(String(thread_id), [])
            index = list.index do |entry|
              entry.fetch("profile_id") == profile_id &&
                entry.fetch("from_digest") == from &&
                entry.fetch("to_digest") == to
            end
            return nil unless index

            candidate = list.fetch(index)
            return nil if candidate.key?("consumed_by")

            consumed_at = Time.now.utc.iso8601
            updated_list = list.dup
            updated_list[index] = candidate.merge(
              "consumed_by" => String(consumed_by),
              "consumed_at" => consumed_at
            )
            updated = current.merge(
              "transitions" => transitions.merge(String(thread_id) => updated_list)
            )
            write_document(updated)
            Transition.new(
              thread_id: String(thread_id),
              profile_id: candidate.fetch("profile_id"),
              from_digest: candidate.fetch("from_digest"),
              to_digest: candidate.fetch("to_digest"),
              reason: candidate.fetch("reason"),
              consumed_by: String(consumed_by),
              consumed_at: consumed_at
            )
          end
        end

        private

        # The registry's single write critical section. flock is advisory but the
        # only writers are the two paths through this class, so both serialize
        # here; flock releases when the descriptor closes (including process
        # death), so a killed writer can never leave the registry wedged.
        def with_registry_lock
          directory = File.dirname(@path)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
          File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            begin
              Profile.verify_permissions!(@path) if File.exist?(@path)
              yield
            ensure
              lock.flock(File::LOCK_UN)
            end
          end
        end

        # Every write bumps the file to schema_version 2 (the codec's only
        # migration step, stated): a v1 file that is recorded onto or consumed
        # from is upgraded in place; v1 files are never rewritten by a mere read.
        def write_document(document)
          document = document.merge("schema_version" => REGISTRY_SCHEMA_VERSION)
          File.write(@path, Psych.dump(document))
          File.chmod(0o600, @path)
        end

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

        # DR-5 D2: backward-compatible READ. v1 documents (the shipped shape,
        # schema_version 1, exact 4-key entries) load unchanged and are never
        # rewritten on read; v2 documents add consumed_by/consumed_at on entries.
        def valid_document?(data)
          return false unless data.is_a?(Hash)
          return false unless [LEGACY_REGISTRY_SCHEMA_VERSION, REGISTRY_SCHEMA_VERSION]
                              .include?(data["schema_version"])
          return false unless data["transitions"].is_a?(Hash)

          data["transitions"].all? do |thread_id, entries|
            thread_id.is_a?(String) && THREAD_PATTERN.match?(thread_id) &&
              entries.is_a?(Array) && entries.all? { |entry| valid_entry?(entry) }
          end
        end

        # v1 entries carry exactly the 4 base keys; v2 entries may add the two
        # consumed keys. Anything else (a partial load, a dropped key, an unknown
        # field) is refused typed rather than partially loaded.
        def valid_entry?(entry)
          return false unless entry.is_a?(Hash)

          base = %w[from_digest profile_id reason to_digest]
          consumed = %w[consumed_at consumed_by]
          keys = entry.keys.sort
          return false unless keys == base.sort || keys == (base + consumed).sort

          PROFILE_ID_PATTERN.match?(entry["profile_id"].to_s) &&
            REASON_PATTERN.match?(entry["reason"].to_s) &&
            DIGEST_PATTERN.match?(entry["from_digest"].to_s) &&
            DIGEST_PATTERN.match?(entry["to_digest"].to_s) &&
            (!entry.key?("consumed_by") || entry["consumed_by"].is_a?(String)) &&
            (!entry.key?("consumed_at") || entry["consumed_at"].is_a?(String))
        end
      end
    end
  end
end

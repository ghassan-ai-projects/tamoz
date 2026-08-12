# frozen_string_literal: true

require "digest"
require "fileutils"
require "forwardable"
require "json"
require "pathname"
require "psych"
require "time"

# The two operator-side registries live beside the loader rather than inside it:
# they share the loader's constants (digest/id patterns, AdoptionError, the
# permission and key-normalization helpers) but nothing in the loader depends on
# them at load time, so they load first and reopen the class.
require_relative "profile/adoption_document"
require_relative "profile/adoption_registry"
require_relative "profile/transition"
require_relative "profile/transition_document"
require_relative "profile/transition_registry"
require_relative "profile/egress_validator"
require_relative "profile/yaml_scanner"
require_relative "profile/check_spec_validator"
require_relative "profile/authority_validator"
require_relative "profile/document_validator"
require_relative "profile/content_scanner"
require_relative "profile/locations"
require_relative "profile/fields"
require_relative "profile/secure_file"

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
      # `model_calls` and `wall_clock_seconds` are the two the WORKER enforces
      # from durable evidence, which is why they are the two that actually bind
      # an unattended run. The rest are recorded and pinned; see
      # docs/LIMITATIONS.md for exactly which are enforced.
      BUDGET_KEYS = %w[
        cost_usd input_tokens output_tokens wall_clock_seconds steps model_calls
      ].freeze
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
        document = load_document(expanded, suggestion: false, env:)
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
      def self.preview(path, suggestion: false, env: ENV)
        load_document(File.expand_path(File.path(path)), suggestion:, env:)
      end

      # The exact bytes that produced a validated document, returned alongside it.
      # `tamoz profile import` installs these rather than re-reading the source: a
      # second read of a repository-controlled path can return different bytes than
      # the ones whose digest the operator just confirmed.
      Source = Data.define(:document, :bytes)

      def self.preview_source(path, suggestion: false, env: ENV)
        expanded = File.expand_path(File.path(path))
        captured = nil
        document = load_document(expanded, suggestion:, env:) { |bytes| captured = bytes }
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
      # same directory entry as `.tamoz/`, so an exact-case parent match let a
      # repository-supplied suggestion be addressed as authority simply by changing
      # the case of the path. Only the reserved suggestion basename is evidence-only:
      # `~/.tamoz/profiles/ops.yaml` is a valid operator runtime profile directory.
      def self.suggestion_path?(expanded_path, env: ENV)
        return false if operator_profile_path?(expanded_path, env:)

        path = Pathname.new(expanded_path)
        path.each_filename.any? { |component| component.downcase == SUGGESTION_DIRECTORY }
      end

      def self.operator_profile_path?(expanded_path, env: ENV)
        profiles = File.expand_path(Locations.profiles_dir(env:))
        expanded_path.start_with?("#{profiles}#{File::SEPARATOR}")
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

      # Where the operator config tree is, and how a requested profile resolves
      # inside it, are Locations' — every answer is a function of the environment.
      # These stay as class methods because the CLI, the evals harness and both
      # registries reach them through Profile.
      def self.resolve_path(profile: nil, profile_id: nil, env: ENV)
        Locations.resolve_path(profile:, profile_id:, env:)
      end

      def self.resolve_explicit(value, env: ENV)
        Locations.resolve_explicit(value, env:)
      end

      def self.config_dir(env: ENV)
        Locations.config_dir(env:)
      end

      def self.profiles_dir(env: ENV)
        Locations.profiles_dir(env:)
      end

      def self.adoption_path(env: ENV)
        Locations.adoption_path(env:)
      end

      def self.transitions_path(env: ENV)
        Locations.transitions_path(env:)
      end

      def self.load_document(expanded_path, suggestion:, env: ENV)
        unless suggestion
          if suggestion_path?(expanded_path, env:)
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
        YamlScanner.call(bytes, expanded_path)
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

      # Opening and reading an operator-owned file safely — O_NOFOLLOW, fstat on
      # the open descriptor, size and encoding limits, and the parent-directory
      # permission walk — is SecureFile's. These stay as class methods because
      # both operator-side registries call verify_permissions! through Profile.
      def self.read_bytes(handle, path)
        SecureFile.read_bytes(handle, path)
      end

      def self.open_verified(path, permissions: true, &)
        SecureFile.open_verified(path, permissions:, &)
      end

      def self.verify_permissions!(path)
        SecureFile.verify_permissions!(path)
      end

      # Single parser pass that rejects load-time code execution vectors before
      # the data model is materialized: tags, excess aliases, duplicate keys.
      # Key/value position inside a mapping is tracked by alternating a flag;
      # containers and aliases also consume a slot in the enclosing mapping.
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

      # The value-level content scan (secrets, interpolation, entropy) is
      # ContentScanner's; YamlScanner is its companion at the event-stream level.
      def self.validate_strings!(value, path, key_path = [])
        ContentScanner.call(value, path, key_path)
      end

      # The declared sections' shapes live in DocumentValidator; these stay as
      # named steps so validate_schema! still reads as the list of checks it runs.
      def self.validate_profile_fields!(profile, path)
        DocumentValidator.profile_fields!(profile, path)
      end

      def self.validate_root!(root, path, field)
        DocumentValidator.root!(root, path, field)
      end

      def self.validate_roots!(hash, profile, path)
        DocumentValidator.roots!(hash, profile, path)
      end

      def self.validate_model_roles!(hash, path)
        DocumentValidator.model_roles!(hash, path)
      end

      def self.validate_budgets!(hash, path)
        DocumentValidator.budgets!(hash, path)
      end

      # A configured check is the profile's execution surface, with its own
      # anti-injection rules; CheckSpecValidator owns them.
      def self.validate_checks!(hash, path)
        CheckSpecValidator.call(hash, path)
      end

      # `tools`, `unattended` and `policy` constrain each other, so AuthorityValidator
      # owns all three. They stay three entry points because the loader calls them at
      # different points and the ORDER decides which error an operator sees first.
      def self.validate_tools!(hash, path)
        AuthorityValidator.tools!(hash, path)
      end

      def self.validate_unattended!(hash, path)
        AuthorityValidator.unattended!(hash, path)
      end

      def self.validate_policy!(hash, tools, path)
        AuthorityValidator.policy!(hash, tools, path)
      end

      # P17 §3: the operator-declared egress policy, validated fail-closed.
      # Absent (`nil`) is the pre-P17 state and means "no governed egress
      # declaration"; present means every field is exact and bounded. The
      # declaration is part of the canonical digest, so any edit is a new
      # profile version that the session-authority machinery re-pins.
      # The egress declaration is one cohesive, fail-closed check with its own
      # vocabulary, so it lives in EgressValidator. Kept as a class method here
      # because both callers — the file loader and the pinned-authority replay —
      # read as a list of validators.
      def self.validate_egress!(hash, path)
        EgressValidator.call(hash, path)
      end

      def self.canonical_digest(hash)
        Tamoz::Core.digest(DIGEST_DOMAIN, hash)
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

      # Fields owns the mapping from validated document to immutable value.
      def self.build_fields(hash, digest:, suggestion:, pinned: false)
        Fields.build(hash, digest:, suggestion:, pinned:)
      end
    end
  end
end

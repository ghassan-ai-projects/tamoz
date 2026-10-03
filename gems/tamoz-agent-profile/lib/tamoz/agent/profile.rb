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
require_relative "profile/pinned_authority"
require_relative "profile/document_loader"

module Tamoz
  module Agent
    # Operator-owned trusted profile (P8). A profile is authority: it pins the
    # canonical root identity, named argv checks, symbolic model roles, budgets,
    # and capability/policy versions for a durable session. Approval policy is
    # not a profile concern: it lives in the approval engine's policy document.
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
      PROFILE_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,63}\z/
      PROFILE_VERSION_PATTERN = /\A[-_.A-Za-z0-9]{1,128}\z/
      CREDENTIAL_REF_PATTERN = /\ATAMOZ_[A-Z0-9_]+\z/
      SUGGESTION_DIRECTORY = ".tamoz"
      SUGGESTION_BASENAME = "suggested-profile.yaml"

      SAFETIES = %w[read_only idempotent unsafe].freeze
      KNOWN_TOOLS = %w[read_file list_directory search_text glob apply_patch create_file run_check load_skill
                       read_skill_resource].freeze
      KNOWN_PROVIDERS = Providers::ENV_KEYS.keys.map(&:to_s).freeze

      TOP_LEVEL_KEYS = %w[profile roots model_roles budgets checks tools policy egress].freeze
      PROFILE_KEYS = %w[schema_version profile_id profile_version canonical_root description].freeze
      ROOTS_KEYS = %w[workspace].freeze
      # P0B/§4.2: `normalized_settings` (e.g. api_base) is the minimally
      # extended role surface the episode path resolves; it is validated as a
      # bounded string mapping, never as a secret (secrets stay in
      # credential_ref).
      MODEL_ROLE_KEYS = %w[provider model credential_ref normalized_settings].freeze
      CREDENTIAL_REF_KEYS = %w[kind name].freeze
      # `model_calls` and `wall_clock_seconds` are the two the WORKER enforces
      # from durable evidence, which is why they are the two that actually bind
      # an unattended run. The rest are recorded and pinned; see
      # docs/LIMITATIONS.md for exactly which are enforced.
      BUDGET_KEYS = %w[
        cost_usd input_tokens output_tokens wall_clock_seconds steps model_calls
      ].freeze
      CHECK_KEYS = %w[argv safety].freeze
      TOOLS_KEYS = %w[allowed].freeze
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
        max_response_bytes connect_timeout_s redirect_max_hops circuit credential_refs page_reads
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
      SECRET_VALUE_PATTERNS = Tamoz::Core::SECRET_VALUE_PATTERNS
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
                     :policy, :canonical_digest,
                     :suggestion, :pinned, :allow_changes?, :high_risk?, :egress

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
          "model_roles" => pinned_model_roles,
          "checks" => checks,
          "tools" => {
            "allowed" => tools_allowed
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

      def pinned_model_roles
        model_roles.transform_values do |role|
          ref = role["credential_ref"]
          if ref
            role.merge("credential_ref" => {"kind" => "env", "name" => ref.fetch("name")})
          else
            role
          end
        end
      end

      def self.load(path, env: ENV, adoption_registry: nil, confirm_adoption: nil)
        expanded = File.expand_path(File.path(path))
        document = DocumentLoader.load(expanded, suggestion: false, env:)
        registry = adoption_registry || AdoptionRegistry.new(env:)
        enforce_activated!(document, registry:, confirm_adoption:)
        document
      end

      def self.enforce_activated!(document, registry:, confirm_adoption:)
        return if registry.activated?(document.profile_id, document.canonical_digest)

        confirmed = confirm_adoption&.call(document)
        unless confirmed
          raise AdoptionError,
                "profile #{document.profile_id.inspect} digest " \
                "#{document.canonical_digest} is not activated in #{registry.path}"
        end

        registry.activate(document.profile_id, document.canonical_digest)
      end

      # Validation-only load used by `tamoz profile preview`. The suggestion flag
      # marks repository-provided files as evidence; it never grants authority.
      def self.preview(path, suggestion: false, env: ENV)
        DocumentLoader.load(File.expand_path(File.path(path)), suggestion:, env:)
      end

      # The exact bytes that produced a validated document, returned alongside it.
      # `tamoz profile import` installs these rather than re-reading the source: a
      # second read of a repository-controlled path can return different bytes than
      # the ones whose digest the operator just confirmed.
      Source = Data.define(:document, :bytes)

      def self.preview_source(path, suggestion: false, env: ENV)
        expanded = File.expand_path(File.path(path))
        captured = nil
        document = DocumentLoader.load(expanded, suggestion:, env:) { |bytes| captured = bytes }
        Source.new(document:, bytes: captured)
      end

      # P8-B §5.4/§5.5: rebuild the authority a session was pinned to from its
      # own checkpoint. The snapshot is treated as untrusted input and re-runs
      # every validator, so a corrupted or tampered checkpoint can only narrow
      # or fail, never widen. Model roles may carry a credential reference NAME
      # (DR-5 RC4), validated by the same `DocumentValidator.model_roles!` gate a profile
      # file passes; replay resolves that env key, never a value stored here.
      def self.from_authority(snapshot, source: "<pinned session authority>")
        PinnedAuthority.document(snapshot, source)
      end

      def self.secret_shape(field, value)
        ContentScanner.classify(field, value)
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

      # Where the operator config tree is, and how a requested profile resolves
      # inside it, are Locations' — every answer is a function of the environment.
      # These stay as class methods because the CLI, the evals harness and both
      # registries reach them through Profile.
      def self.resolve_path(profile: nil, profile_id: nil, env: ENV)
        Locations.resolve_path(profile:, profile_id:, env:)
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

      def self.verify_permissions!(path)
        SecureFile.verify_permissions!(path)
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

      def self.required_hash(hash, key, path)
        value = hash[key]
        raise ValidationError, "#{path}: missing required section #{key.inspect}" unless value.is_a?(Hash)

        value
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
    end
  end
end

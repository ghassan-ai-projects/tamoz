# frozen_string_literal: true

require 'digest'
require 'pathname'

require_relative 'check_receipt'
require_relative 'check_runner'
require_relative 'creation_operations'
require_relative 'patch_operations'
require_relative 'patch_preparation'
require_relative 'path_resolver'
require_relative 'read_operations'
require_relative 'staging_reaper'
require_relative 'tool_argument_validator'
require_relative 'tool_catalog'
require_relative 'tool_policy_normalizer'

module Tamoz
  module Tools
    # Public capability façade. Policy, execution, and filesystem boundaries live in collaborators.
    # :reek:BooleanParameter :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall
    # :reek:FeatureEnvy :reek:InstanceVariableAssumption :reek:LongParameterList :reek:MissingSafeMethod
    # :reek:RepeatedConditional :reek:TooManyConstants :reek:TooManyInstanceVariables
    # :reek:TooManyMethods :reek:TooManyStatements :reek:UtilityFunction
    class Toolbox
      MAX_FILE_BYTES = 64 * 1024
      MAX_REPLACEMENTS = 32
      MAX_DIRECTORY_ENTRIES = 200
      MAX_SEARCH_FILES = 2_000
      MAX_SEARCH_RESULTS = 100
      MAX_PATCH_BYTES = 64 * 1024
      MAX_CHECK_OUTPUT_BYTES = 64 * 1024
      DEFAULT_CHECK_TIMEOUT = 60.0

      attr_reader :root, :checks, :check_timeout, :check_safeties, :approval_required, :skills, :skill_catalog, :reaped_staging, :catalog_digest, :prompt_surface_digest

      def initialize(
        root:,
        allow_changes: false,
        checks: {},
        check_timeout: DEFAULT_CHECK_TIMEOUT,
        check_safeties: {},
        allowed_tools: nil,
        approval_required: nil,
        skills: Skills::Snapshot.empty,
        reap_staging: true
      )
        @root = Pathname.new(root).expand_path.realpath.freeze
        raise ToolError, 'workspace root is not a directory' unless @root.directory?
        @path_resolver = PathResolver.new(@root)
        validate_options(allow_changes, check_timeout, skills)
        @allow_changes = allow_changes
        @check_timeout = check_timeout.to_f
        @skills = skills
        @skill_catalog = Skills::Catalog.new(skills)
        catalog = ToolCatalog.new(allow_changes:, checks:, check_safeties:, allowed_tools:, approval_required:, skills:)
        assign_catalog(catalog)
        @argument_validator = ToolArgumentValidator.new(
          names: @descriptions.keys, checks: @checks, path_resolver: @path_resolver, skill_catalog: @skill_catalog
        )
        @reaped_staging = @allow_changes && reap_staging ? StagingReaper.new(@root).reap : [].freeze
      rescue SystemCallError
        raise ToolError, 'workspace root is unavailable'
      end

      def self.credential_free_env(env = ENV) = CheckRunner.credential_free_env(env)
      def self.credential_env?(name) = CheckRunner.credential_env?(name)

      def self.observe(path)
        return {'state' => 'absent'} unless path.exist?
        return {'state' => 'not_a_regular_file'} unless path.file?
        return {'state' => 'symlink'} if path.symlink?

        content = path.read(mode: 'rb')
        {'state' => Digest::SHA256.hexdigest(content), 'mode' => path.stat.mode & 0o777}
      rescue SystemCallError
        {'state' => 'unreadable'}
      end

      def descriptions = @descriptions
      def names = descriptions.keys
      def allowed_tools = @allowed_tools

      def read_only_names
        candidates = ToolCatalog::READ_DESCRIPTIONS.keys
        candidates += ToolCatalog::SKILL_DESCRIPTIONS.keys unless @skills.empty?
        candidates.select { |name| @allowed_tools.include?(name) }
      end

      def skill_catalog_digest = @skills.catalog_digest
      def skill_epoch = @skills.empty? ? Tamoz::Core::LEGACY_SKILL_EPOCH : @skills.epoch
      def action_capable? = @allow_changes
      def approval_required?(name) = @approval_required.include?(String(name))
      def check_safety(name) = @catalog.check_safety(name)

      def maximum_effect_output_bytes(name)
        case String(name)
        when 'apply_patch', 'create_file' then 6 * 1024
        when 'run_check' then MAX_CHECK_OUTPUT_BYTES + 1024
        else 0
        end
      end

      def validate(name, arguments) = @argument_validator.validate(name, arguments)

      def execute(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)
        case normalized_name
        when 'read_file' then ReadOperations.new(self).read_file(normalized_arguments)
        when 'list_directory' then ReadOperations.new(self).list_directory(normalized_arguments)
        when 'search_text' then ReadOperations.new(self).search_text(normalized_arguments)
        when 'apply_patch' then PatchOperations.new(self).apply(normalized_arguments)
        when 'run_check' then CheckRunner.new(self).run(normalized_arguments)
        when 'create_file' then CreationOperations.new(self).create(normalized_arguments)
        when 'load_skill' then load_skill(normalized_arguments)
        when 'read_skill_resource' then read_skill_resource(normalized_arguments)
        else raise ToolError, "unknown tool #{normalized_name.inspect}"
        end
      end

      def effect_intent(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)
        case normalized_name
        when 'apply_patch'
          patch = patch_operations.prepare(patch_operations.resolved_arguments(normalized_arguments))
          {'path' => normalized_arguments.fetch('path'), 'before_state' => patch.fetch(:before_digest),
           'after_digest' => Digest::SHA256.hexdigest(patch.fetch(:after_content))}.freeze
        when 'create_file'
          {'path' => normalized_arguments.fetch('path'), 'before_state' => 'absent',
           'after_digest' => normalized_arguments.fetch('expected_sha256'),
           'after_mode' => normalized_arguments.fetch('mode').to_i(8)}.freeze
        else
          {}.freeze
        end
      end

      def preview(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)
        case normalized_name
        when 'apply_patch'
          patch = patch_operations.prepare(patch_operations.resolved_arguments(normalized_arguments))
          patch_operations.render_diff(normalized_arguments.fetch('path'), patch)
        when 'run_check'
          argv = checks.fetch(normalized_arguments.fetch('name'))
          "$ #{argv.map { |entry| CheckRunner.shell_display(entry) }.join(' ')}"
        when 'create_file'
          CreationOperations.new(self).preview(normalized_arguments.fetch('path'), normalized_arguments.fetch('content'),
                                               normalized_arguments.fetch('mode'), normalized_arguments.fetch('expected_sha256'))
        else
          raise ToolError, "tool #{normalized_name.inspect} does not require approval"
        end
      end

      def reap_stale_staging(older_than: StagingReaper::DEFAULT_AGE, now: Time.now)
        StagingReaper.new(@root).reap(older_than:, now:)
      end

      private

      attr_reader :catalog

      def assign_catalog(catalog)
        @catalog = catalog
        @checks = catalog.checks
        @check_safeties = catalog.check_safeties
        @allowed_tools = catalog.allowed_tools
        @approval_required = catalog.approval_required
        @descriptions = catalog.descriptions
        @catalog_digest = catalog.catalog_digest
        @prompt_surface_digest = catalog.prompt_surface_digest
      end

      def validate_options(allow_changes, check_timeout, skills)
        unless allow_changes == true || allow_changes == false
          raise ArgumentError, 'allow_changes must be true or false'
        end
        unless check_timeout.is_a?(Numeric) && check_timeout.positive? && check_timeout <= 600
          raise ArgumentError, 'check_timeout must be between 0 and 600 seconds'
        end
        raise ArgumentError, 'skills must be a Tamoz::Agent::Skills::SkillSnapshot' unless skills.is_a?(Skills::SkillSnapshot)
      end

      def patch_operations = PatchOperations.new(self)
      def prepare_patch(arguments) = patch_operations.prepare(arguments)
      def render_diff(path, patch) = patch_operations.render_diff(path, patch)

      def load_skill(arguments)
        record = @skill_catalog.resolve(arguments.fetch('skill'))
        Skills.render_load(record, available_tools: names)
      end

      def read_skill_resource(arguments)
        record = @skill_catalog.resolve(arguments.fetch('skill'))
        path = arguments.fetch('path')
        Skills.render_resource(record, path, Skills.read_resource(record, path))
      end

      def resolve(raw_path, type:, allow_symlinks: true)
        allow_symlinks ? @path_resolver.resolve(raw_path, type:) : @path_resolver.resolve_without_symlinks(raw_path, type:)
      end

      def validate_create_path!(raw_path) = @path_resolver.validate_create_path!(raw_path)

      def fsync_directory(directory)
        File.open(directory.to_s, File::RDONLY, &:fsync)
      rescue SystemCallError
        nil
      end
    end
  end
end

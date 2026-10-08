# frozen_string_literal: true

require 'fileutils'

module Tamoz
  module Agent
    class CLI
      # Assembles and tears down a durable CLI session.
      class SessionBuilder
        Parts = Data.define(:model, :toolbox, :adapter, :mcp, :memory, :approvals, :harness)

        APPROVAL_SESSION = 'interactive'
        MAX_LEASE_TTL = 30.0

        def initialize(env:, models:)
          @env = env
          @models = models
        end

        def resolve_session_dir(options)
          return File.expand_path(options[:session_dir]) if options[:session_dir]
          return File.expand_path(@env['TAMOZ_SESSION_DIR']) if @env['TAMOZ_SESSION_DIR']

          if RUBY_PLATFORM.include?('darwin')
            File.expand_path('~/Library/Application Support/tamoz/sessions')
          else
            File.join(@env['XDG_STATE_HOME'] || File.expand_path('~/.local/state'), 'tamoz', 'sessions')
          end
        end

        def provision_session_dir!(options)
          session_dir = resolve_session_dir(options)
          FileUtils.mkdir_p(session_dir, mode: 0o700)
          return session_dir if File.stat(session_dir).mode.nobits?(0o077)

          raise ArgumentError, "session directory #{session_dir} is accessible to group or others"
        end

        def lease_ttl
          raw = @env['TAMOZ_LEASE_TTL']
          return MAX_LEASE_TTL if raw.to_s.empty?

          ttl = Float(raw, exception: false)
          return ttl if ttl&.positive? && ttl <= MAX_LEASE_TTL

          raise ArgumentError, 'TAMOZ_LEASE_TTL must be a number of seconds within (0, 30]'
        end

        def build_mcp_source(options, profile: nil)
          runtime_path = options[:runtime_dir] || @env['TAMOZ_RUNTIME_DIR']
          return nil unless runtime_path

          directory = RuntimeDirectory.resolve(path: runtime_path, env: @env)
          expected_root = profile ? profile.canonical_root : options[:root]
          unless File.expand_path(directory.workspace_root) == File.expand_path(expected_root)
            raise ArgumentError,
                  "runtime workspace #{directory.workspace_root.inspect} does not match " \
                  "the CLI workspace #{expected_root.inspect}"
          end

          McpSourceBuilder.new(directory).build
        end

        def assemble(options, thread_id, read_only:, profile:, openers:)
          require 'tamoz/sqlite'

          session_dir = provision_session_dir!(options)
          model = read_only ? read_only_model : @models.build(options, profile:)
          toolbox = build_toolbox(options, profile:)
          adapter = build_adapter(session_dir, thread_id)
          mcp = nil
          memory = nil
          begin
            mcp = build_mcp_source(options, profile:) unless read_only
            memory = openers[:memory].call unless read_only
            parts = Parts.new(model:, toolbox:, adapter:, mcp:, memory:, approvals: build_approvals(options),
                              harness: openers[:harness].call)
            yield parts, build_session(parts, options:, thread_id:, profile:)
          ensure
            close_run_resources(mcp, memory, read_only:, adapter:)
          end
        end

        def build_list_session(adapter, options)
          model = Object.new
          def model.generate(**) = '{}'
          toolbox = Tamoz::Agent::Toolbox.new(root: options[:root], allow_changes: options[:allow_changes],
                                              checks: options[:checks])
          Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter)
        end

        private

        def close_run_resources(mcp, memory, read_only:, adapter:)
          mcp&.close
          memory&.first&.close
          adapter.close unless read_only
        end

        def build_session(parts, options:, thread_id:, profile:)
          SkillsOptions.require_loadable!(parts.toolbox, parts.harness[:skill])
          engine, owner, = parts.memory
          tenant = "session:#{thread_id}"
          Tamoz::Agent::Session.new(
            memory: engine, memory_owner: owner, model: parts.model, toolbox: parts.toolbox,
            checkpointer: parts.adapter, profile:, approval_engine: parts.approvals,
            approval_session_id: APPROVAL_SESSION, profile_roles: @models.resolve_profile_roles(profile, options),
            profile_budgets: profile&.budgets, mcp: parts.mcp,
            artifact_store: parts.adapter.bind_artifact_store(tenant:), artifact_tenant: tenant,
            routing: durable_routing(options), harness: parts.harness
          )
        end

        def read_only_model
          model = Object.new
          def model.generate(**)
            raise Tamoz::Core::ToolError, 'a read-only command must not generate'
          end
          model
        end

        def build_adapter(session_dir, thread_id)
          Tamoz::SQLite::Adapter.new(
            path: File.join(session_dir, "#{thread_id}.sqlite3"),
            limits: Tamoz::SQLite::Limits.new(lease_ttl:)
          )
        end

        def build_toolbox(options, profile: nil)
          return build_profile_toolbox(profile, options) if profile

          Tamoz::Agent::Toolbox.new(
            root: options[:root], allow_changes: options[:allow_changes], checks: options[:checks],
            skills: SkillsOptions.new(options).snapshot(options[:root])
          )
        end

        def build_approvals(options)
          engine = Tamoz::Agent.build_approval_engine(profile_name: options[:approval_profile] || 'review')
          engine.bind_session(APPROVAL_SESSION)
          engine
        end

        def build_profile_toolbox(profile, options)
          skills = SkillsOptions.new(options).snapshot_for(profile)
          checks = profile.checks
          Tamoz::Agent::Toolbox.new(
            root: profile.canonical_root, allow_changes: profile.allow_changes?,
            checks: checks.transform_values { |check| check.fetch('argv') },
            check_safeties: checks.transform_values { |check| check.fetch('safety').to_sym },
            allowed_tools: profile.tools_allowed, skills:
          )
        end

        def durable_routing(options)
          if options[:work_routing] then :work
          elsif options[:adaptive_routing] then :adaptive
          elsif options[:experimental_routing] then :experimental
          else :legacy
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # Where the operator's config tree is, and how a requested profile resolves
      # to a path inside it (§3.3).
      #
      # Everything here is a function of the ENVIRONMENT, which is why it holds
      # one: the config root, the profiles directory, and both registry paths all
      # derive from the same three variables, and tests and sandboxed runs
      # redirect the whole tree by setting `TAMOZ_CONFIG_HOME`.
      #
      # Resolution is a strict precedence — an explicit flag beats
      # `TAMOZ_PROFILE`, which beats `TAMOZ_PROFILE_ID`, which falls back to the
      # profiles directory — and `nil` is a real answer meaning "no profile was
      # requested", not a failure.
      #
      # Pinned by test/agent_profile_test.rb (resolve_path precedence, env
      # profile id never resolving to a cwd file) and test/agent_cli_profile_test.
      #
      # :reek:ControlParameter — `profile:` and `profile_id:` ARE the precedence
      # question. nil means "not requested at this level, fall through", which is
      # the whole contract; collapsing them would remove the ordering.
      class Locations
        SUFFIX = '.yaml'

        class << self
          def resolve_path(profile: nil, profile_id: nil, env: ENV)
            new(env).resolve_path(profile:, profile_id:)
          end

          def resolve_explicit(value, env: ENV)
            new(env).resolve_explicit(value)
          end

          def config_dir(env: ENV)
            new(env).config_dir
          end

          def profiles_dir(env: ENV)
            new(env).profiles_dir
          end

          def adoption_path(env: ENV)
            new(env).adoption_path
          end

          def transitions_path(env: ENV)
            new(env).transitions_path
          end
        end

        def initialize(env)
          @env = env
        end

        # Returns nil when nothing was requested; the caller then proceeds
        # without a profile.
        def resolve_path(profile: nil, profile_id: nil)
          explicit = profile || @env['TAMOZ_PROFILE']
          return resolve_explicit(explicit) if explicit

          id = profile_id || @env['TAMOZ_PROFILE_ID']
          id ? in_profiles_dir(id) : nil
        end

        # An absolute path is taken as given; a bare profile id names a file in
        # the profiles directory; anything else is a path relative to the working
        # directory. The id branch is what stops `TAMOZ_PROFILE_ID=x` from ever
        # resolving to a file in the current directory.
        def resolve_explicit(value)
          text = String(value)
          return text if text.start_with?(File::SEPARATOR)
          return in_profiles_dir(text) if PROFILE_ID_PATTERN.match?(text)

          File.expand_path(text, Dir.pwd)
        end

        # TAMOZ_CONFIG_HOME redirects the whole operator config tree (profiles,
        # adoption registry); it exists for sandboxed runs and tests.
        def config_dir
          override = @env['TAMOZ_CONFIG_HOME']
          return File.expand_path(override) if override.to_s != ''

          platform_config_dir
        end

        def profiles_dir
          File.join(config_dir, 'profiles')
        end

        def adoption_path
          File.join(config_dir, 'adoption.yaml')
        end

        def transitions_path
          File.join(config_dir, 'transitions.yaml')
        end

        private

        def platform_config_dir
          return File.expand_path('~/Library/Application Support/tamoz') if RUBY_PLATFORM.include?('darwin')

          base = @env['XDG_CONFIG_HOME'] || File.expand_path('~/.config')
          File.join(base, 'tamoz')
        end

        def in_profiles_dir(id)
          File.join(profiles_dir, "#{id}#{SUFFIX}")
        end
      end
    end
  end
end

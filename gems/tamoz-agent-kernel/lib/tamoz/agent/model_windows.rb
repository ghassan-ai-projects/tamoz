# frozen_string_literal: true

require 'yaml'

module Tamoz
  module Agent
    # The documented window and output cap of each model route, and the operator's concurrency pin, from data.
    #
    # The data is the authority for a route the profile does not override; a route that is not
    # recorded has no window and the caller refuses rather than guessing. `source` and `checked`
    # in the file say where each number came from and when.
    # :reek:DataClump -- (provider, model) is the route key every lookup takes, by design.
    module ModelWindows
      DATA = File.expand_path('../../../data/model_windows.yml', __dir__)
      DEFAULT_REQUEST_TIMEOUT_S = 120

      class << self
        def routes = @routes ||= load_routes

        # The recorded window for a route, or nil when the route is not documented.
        def window(provider:, model:) = entry(provider:, model:)&.fetch('context_window', nil)

        # How many requests the operator lets this route carry at once; an unpinned route runs one at a time.
        def max_concurrent_requests(provider:, model:)
          entry(provider:, model:)&.fetch('max_concurrent_requests', nil) || 1
        end

        # Seconds to wait for one response; a reasoning model may think past the default.
        def request_timeout(provider:, model:)
          entry(provider:, model:)&.fetch('request_timeout_s', nil) || DEFAULT_REQUEST_TIMEOUT_S
        end

        # Keyed on the pair: one model name can have a different window at each gateway, so a bare
        # model key would apply one provider's number to another provider's route.
        def entry(provider:, model:) = routes["#{provider}/#{model}"]

        private

        def load_routes
          data = YAML.safe_load_file(DATA, aliases: false)
          raise Error, "model windows: #{DATA} is not a mapping" unless data.is_a?(Hash)

          rules = data.fetch('routes')
          raise Error, "model windows: #{DATA} has no routes" unless rules.is_a?(Hash) && !rules.empty?

          Tamoz::Core.deep_freeze(rules)
        end
      end
    end
  end
end

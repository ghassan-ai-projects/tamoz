# frozen_string_literal: true

require 'yaml'

module Tamoz
  module Agent
    # The documented window and output cap of each model route, read from pinned data.
    #
    # The data is the authority for a route the profile does not override; a route that is not
    # recorded has no window and the caller refuses rather than guessing. `source` and `checked`
    # in the file say where each number came from and when.
    module ModelWindows
      DATA = File.expand_path('../../../data/model_windows.yml', __dir__)

      class << self
        def routes = @routes ||= load_routes

        # The recorded window for a route, or nil when the route is not documented.
        def window(provider:, model:) = entry(provider:, model:)&.fetch('context_window', nil)

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

# frozen_string_literal: true

module Tamoz
  module Agent
    # One first-party channel kind: its adapter gem is loaded only when a command needs it; `options` reach the
    # adapter's constructors (a test's fixture client).
    ChannelKind = Data.define(:name, :library, :namespace, :options) do
      def initialize(name:, library:, namespace:, options: {}) = super

      def channel = adapter.const_get(:Channel).new(**options)

      def setup = adapter.const_get(:Setup).new(**options)

      private

      def adapter
        require library
        Object.const_get(namespace)
      rescue LoadError => e
        raise unless e.path == library

        raise CLICommsShared::MissingAdapterError, "the #{name} channel (#{library.tr('/', '-')}) is not installed"
      end
    end

    # The closed set of channel kinds: configuration can name only these.
    CHANNEL_KINDS = [
      ChannelKind.new(name: 'telegram', library: 'tamoz/telegram', namespace: 'Tamoz::Telegram'),
      ChannelKind.new(name: 'talk', library: 'tamoz/talk', namespace: 'Tamoz::Talk')
    ].to_h { |kind| [kind.name, kind] }.freeze
  end
end

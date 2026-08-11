# frozen_string_literal: true

require_relative 'shapes'

module Tamoz
  module Comms
    # The closed command table (design §8). There is no text approval command
    # and no command that names a profile, tool, root, model, budget or
    # schedule. An unknown slash command gets a typed `unknown_command` control
    # reply and never becomes model input.
    module Commands
      KNOWN = %w[help status new cancel redirect whoami].freeze

      # The typed command crossing admission into the gateway. It carries no
      # free-form task text and is never a model prompt.
      CommandIntent = Data.define(:name, :arguments)

      # A parsed known command. `arguments` is nil when absent.
      Command = Data.define(:command, :arguments) do
        def intent = CommandIntent.new(name: command, arguments:)
      end

      module_function

      # @param text [String] envelope text (already SafeText-normalized).
      # @param bot_username [String, nil] the authenticated bot's username.
      # @return [Command, nil] the parsed known command, or nil when the text
      #   is not a known command (not a slash, unknown, or a wrong-username
      #   suffix).
      # :reek:ControlParameter, :reek:TooManyStatements -- the parse branches
      # ARE the command grammar (suffix rule, argument split).
      def parse(text, bot_username: nil)
        return nil unless text.start_with?('/')

        command_word, _, remainder = text.delete_prefix('/').partition(/\s/)
        word, _, suffix = command_word.partition('@')
        normalized = word.downcase
        return nil unless KNOWN.include?(normalized) && matching_suffix?(suffix, bot_username)

        Command.new(command: normalized, arguments: clean(remainder))
      end

      def known?(command) = KNOWN.include?(command)

      def looks_like_command?(text) = text.start_with?('/')

      # Telegram's optional @bot_username suffix is accepted only when it
      # matches the authenticated bot; without one, any suffix is refused.
      def matching_suffix?(suffix, bot_username)
        suffix.empty? || suffix == bot_username
      end

      # :reek:NilCheck -- nil is the legitimate "no arguments" state.
      def clean(arguments)
        return nil if arguments.nil?

        stripped = arguments.strip
        stripped.empty? ? nil : stripped
      end
      private_class_method :clean, :matching_suffix?
    end
  end
end

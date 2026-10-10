# frozen_string_literal: true

require_relative 'shapes'

module Tamoz
  module Comms
    # The closed command table (design §8). There is no text approval command
    # and no command that names a profile, tool, root, model, budget or
    # schedule. An unknown slash command gets a typed `unknown_command` control
    # reply and never becomes model input.
    module Commands
      KNOWN = %w[help status new cancel redirect whoami start reset compact usage context think verbose answer
                 research].freeze

      # The typed command crossing admission into the gateway. Only /redirect, /answer and /research carry text meant
      # for the model (a replacement task, an answer, a research question); the command itself is never a prompt.
      CommandIntent = Data.define(:name, :arguments)

      # A parsed known command. `arguments` is nil when absent.
      Command = Data.define(:command, :arguments) do
        def intent = CommandIntent.new(name: command, arguments:)
      end

      module_function

      # @param text [String] envelope text (already SafeText-normalized).
      # @return [Command, nil] the parsed known command, or nil when the text
      #   is not a known command (not a slash, unknown, or an `@name` suffix
      #   the channel's normalizer did not strip as its own).
      # :reek:TooManyStatements -- the parse branches ARE the command grammar.
      def parse(text)
        return nil unless text.start_with?('/')

        command_word, _, remainder = text.delete_prefix('/').partition(/\s/)
        word, _, suffix = command_word.partition('@')
        normalized = word.downcase
        return nil unless KNOWN.include?(normalized) && suffix.empty?

        Command.new(command: normalized, arguments: clean(remainder))
      end

      def known?(command) = KNOWN.include?(command)

      def looks_like_command?(text) = text.start_with?('/')

      # :reek:NilCheck -- nil is the legitimate "no arguments" state.
      def clean(arguments)
        return nil if arguments.nil?

        stripped = arguments.strip
        stripped.empty? ? nil : stripped
      end
      private_class_method :clean
    end
  end
end

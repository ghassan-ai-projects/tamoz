# frozen_string_literal: true

# Tamoz::Agent::CLI::PromptAdapter — the interactive approval/clarify seam
# (Q3 slice 2). Owns the prompt LOOPS that read operator answers from input
# and write prompts to err. The CLI owns the answer POLICY (answer_for,
# map_answer, non-interactive routing) and delegates the mechanics here.
# Prompt text is a stable user-facing contract: byte-identical output.
module Tamoz
  module Agent
    class CLI
      # Reads operator answers for the CLI's approval/clarify prompts. EOF
      # (nil input) aborts the prompt — the caller treats nil as "no answer".
      class PromptAdapter
        APPROVE = %w[y yes a approve].freeze
        DENY = %w[n no d deny].freeze
        HELP = %w[? h help].freeze

        def initialize(input:, err:)
          @input = input
          @err = err
        end

        # :reek:TooManyStatements :reek:RepeatedConditional :reek:NilCheck --
        # the approval loop is a stateful read-validate-retry loop; the nil-check
        # at the loop head is the EOF-aborts-prompt contract.
        def approve_tool(descriptor)
          tool = descriptor['tool']
          @err.puts "Approval required for #{tool}:\n#{descriptor['preview']}"
          loop do
            line = read_line("Approve #{tool}? [y/N/?] ")
            return nil if line.nil?

            case line.strip.downcase
            when *APPROVE then return true
            when *DENY then return false
            when *HELP then print_approval_help
            else print_invalid_approval
            end
          end
        end

        # :reek:TooManyStatements :reek:RepeatedConditional :reek:NilCheck --
        # same stateful loop and EOF-aborts contract as approve_tool.
        def clarify(descriptor)
          @err.puts descriptor['question']
          loop do
            line = read_line('Answer: ')
            return nil if line.nil?

            answer = line.strip
            return answer unless answer.empty?

            @err.puts 'Answer must be non-empty.'
          end
        end

        def interrupt(descriptor)
          @err.puts "Interrupt: #{descriptor['kind']}"
          read_line('Answer: ')&.strip
        end

        private

        def print_approval_help
          @err.puts "y/yes/a/approve: approve the operation\nn/no/d/deny: deny the operation"
        end

        def print_invalid_approval
          @err.puts 'Invalid answer. Enter y/yes, n/no, a/approve, d/deny, or ? for help.'
        end

        def read_line(prompt)
          @err.print prompt
          @err.flush
          @input.gets
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Agenteval
  module Research
    # A model of a different family from the one researching, over an OpenAI-compatible endpoint. It judges citation
    # support (a sentence against the excerpts it cites) and compares two reports on the rubric.
    class Judge
      RUBRIC = %w[comprehensiveness insight instruction_following readability].freeze
      BATCH = 10

      # The reply's one JSON object, however deeply it nests; a flat regex match would grab an inner one instead.
      def self.object_in(text)
        start = text.index("{")
        return unless start

        depth = 0
        text[start..].each_char.with_index do |char, offset|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
          return text[start, offset + 1] if depth.zero?
        end
        nil
      end

      def initialize(base:, key:, model:)
        @uri = URI("#{base.chomp('/')}/chat/completions")
        @key = key
        @model = model
      end

      # [true/false per item]; an item with no excerpt is unsupported without asking.
      def supported(items)
        items.each_slice(BATCH).flat_map do |batch|
          asked = batch.each_with_index.reject { |item, _| item.fetch("excerpts").empty? }
          verdicts = asked.empty? ? [] : answer(support_prompt(asked.map(&:first)), "supported")
          answers = asked.map(&:last).zip(verdicts).to_h
          batch.each_index.map { |index| answers[index] == true }
        end
      end

      # {criterion => "A" | "B" | "tie"}; the caller swaps the order and keeps only consistent winners.
      def compare(question, first, second)
        ask(<<~PROMPT).slice(*RUBRIC)
          Two research reports answer the same question. Judge each criterion: which report is better, "A", "B" or
          "tie". Ignore length for its own sake.
          comprehensiveness: covers what the question needs. insight: explains, weighs and connects, not only lists.
          instruction_following: answers exactly the question asked. readability: clear structure and prose.
          Reply with JSON only: {"comprehensiveness": "A", "insight": "B", "instruction_following": "tie", "readability": "A"}

          Question: #{question}

          Report A:
          #{first}

          Report B:
          #{second}
        PROMPT
      end

      private

      # The judge sometimes answers without the field asked for; three tries, then the grade is missing, not guessed.
      def answer(prompt, key)
        3.times do
          value = ask(prompt)[key]
          return value if value
        end
        raise "the judge gave no #{key.inspect} after three tries"
      end

      def support_prompt(items)
        listed = items.each_with_index.map do |item, index|
          quotes = item.fetch("excerpts").map { |excerpt| "   > #{excerpt}" }.join("\n")
          "#{index + 1}. Sentence: #{item.fetch('sentence')}\n   Excerpts:\n#{quotes}"
        end
        <<~PROMPT
          For each numbered sentence, decide whether the quoted excerpts, and nothing else you know, support what the
          sentence states. Citation markers like [1] are not part of the claim. Partly supported counts as false.
          Reply with JSON only: {"supported": [true, false, ...]} with one entry per sentence, in order.

          #{listed.join("\n\n")}
        PROMPT
      end

      def ask(prompt)
        request = Net::HTTP::Post.new(@uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{@key}")
        request.body = JSON.generate(model: @model, temperature: 0, response_format: { type: "json_object" },
                                     messages: [{ role: "user", content: prompt }])
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, read_timeout: 300) { |http| http.request(request) }
        raise "judge answered HTTP #{response.code}: #{response.body.to_s[0, 200]}" unless response.code == "200"

        content = JSON.parse(response.body).dig("choices", 0, "message", "content").to_s
        JSON.parse(Judge.object_in(content) || "{}")
      end
    end
  end
end

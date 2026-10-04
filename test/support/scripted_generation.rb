# frozen_string_literal: true

require 'json'

module ScriptedGeneration
  def generate(stage:, system:, prompt:)
    @calls << { stage:, system:, prompt: }
    queue = @responses.fetch(stage)
    raise "no scripted #{stage} response" if queue.empty?

    value = queue.length == 1 ? queue.first : queue.shift
    value.is_a?(String) ? value : JSON.generate(value)
  end
end

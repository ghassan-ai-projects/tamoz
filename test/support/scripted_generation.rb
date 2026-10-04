# frozen_string_literal: true

require 'json'

module ScriptedGeneration
  class Model
    include ScriptedGeneration

    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end
  end

  class QueueModel
    attr_reader :calls

    def initialize(plan:, review:, verify:)
      @responses = { plan:, review:, verify: }.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << { stage:, system:, prompt: }
      value = @responses.fetch(stage).shift
      raise "missing #{stage} response" unless value

      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def generate(stage:, system:, prompt:)
    @calls << { stage:, system:, prompt: }
    queue = @responses.fetch(stage)
    raise "no scripted #{stage} response" if queue.empty?

    value = queue.length == 1 ? queue.first : queue.shift
    value.is_a?(String) ? value : JSON.generate(value)
  end
end

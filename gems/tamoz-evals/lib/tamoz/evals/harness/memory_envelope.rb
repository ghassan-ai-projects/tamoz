# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # DR-3 model boundary: the retrieval + injection seam on the agent turn
      # stream. Wraps a controller-scripted model; for every `generate` the
      # envelope consults the retrieval layer, renders the injected records into
      # the effective prompt, emits one `:memory_recalled` event per record (the
      # ONLY attribution mark), and snapshots the turn into `captures`. The
      # inner scripted model ignores the prompt, so CI structurally cannot claim
      # reuse attribution (C1) — it measures injection correctness: the decisive
      # turn's prompt carries EXACTLY the records the store + policy should have
      # injected, and prompt-injected content is never absorbed into retrieval.
      class MemoryEnvelope
        MEMORY_EVENT = :memory_recalled
        MEMORY_CONTEXT_HEADER = "# Memory context"
        INJECTION_MARKER = "MEMORY INJECTION"

        attr_reader :inner

        def initialize(inner:, store:, retrieval:, events:, captures:)
          @inner = inner
          @store = store
          @retrieval = retrieval
          @events = events
          @captures = captures
        end

        # The corpus runner reads the scripted model's call log for metrics.
        def calls = @inner.calls

        def generate(stage:, system:, prompt:)
          recall = @retrieval.recall(store: @store, query: prompt)
          records = recall.injected_ids.map { |memory_id| @store.record(memory_id) }
          prompt_echoed = records.select do |record|
            prompt.include?(CanonicalJSON.dump(record.fetch("content")))
          end.map { |record| record.fetch("memory_id") }
          effective = render(prompt, records)

          records.each do |record|
            @events << Tamoz::Agent::Event.new(
              type: MEMORY_EVENT,
              data: DeepFreeze.call(
                "stage" => stage.to_s,
                "memory_id" => record.fetch("memory_id"),
                "record_version" => record.fetch("record_version"),
                "epoch" => record.fetch("epoch"),
                "classification" => record.fetch("classification"),
                "authorized" => true
              )
            )
          end
          @captures << DeepFreeze.call(
            "stage" => stage.to_s,
            "injected_ids" => recall.injected_ids,
            "matched_restricted_ids" => recall.matched_restricted_ids,
            "prompt_echoed_ids" => prompt_echoed,
            "prompt_injections" => prompt.scan(INJECTION_MARKER).length,
            "original_prompt" => prompt,
            "effective_prompt" => effective
          )
          @inner.generate(stage:, system:, prompt: effective)
        end

        private

        def render(prompt, records)
          return prompt if records.empty?

          block = records.map do |record|
            "  - [#{record.fetch("memory_id")} v#{record.fetch("record_version")}] " \
              "#{CanonicalJSON.dump(record.fetch("content"))}"
          end.join("\n")
          "#{prompt}\n\n#{MEMORY_CONTEXT_HEADER}\n#{block}\n"
        end
      end
    end
  end
end

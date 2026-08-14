# frozen_string_literal: true

# The bin/tamoz-stream-worker graph fixture: a DIAGNOSE episode that reads
# the verified snapshot's facts and proposes a decision. The launcher
# convention is build_episode_app(checkpointer) -> a compiled app.

require "tamoz/stream/reconsideration"

def build_episode_app(checkpointer)
  graph = Tamoz.graph(name: "episode-diagnose", version: "1") do
    state :episode, default: {}
    state :snapshot, default: {}
    state :reconsideration, default: nil
    state :primary_hypothesis, default: nil
    state :confidence, default: nil
    state :summary, default: nil
    state :facts_used, default: []
    state :alternatives, default: []
    state :compensating_intents, default: []
    state :situation_memory, default: [], immutable: true
    state :memory_record_digests, default: [], immutable: true
    node(:analyze, implementation_name: "episode.analyze", version: "1") do |state, context|
      episode = state.fetch(:episode)
      if episode.fetch("kind") == "reconsider"
        data = state.fetch(:reconsideration)
        parsed = Tamoz::Stream::Reconsideration.from_hash(data)
        judgements = Tamoz::Stream::Reconsideration.judge(parsed:)
        snapshot = state.fetch(:snapshot)
        {
          primary_hypothesis: "correction explains the signal",
          confidence: 0.9,
          summary: "prior decision corrected",
          compensating_intents: Tamoz::Stream::Reconsideration.build_compensating_intents(
            judgements,
            episode: {
              episode_id: episode.fetch("episode_id"),
              attempt_id: episode.fetch("attempt_id"),
              fence: episode.fetch("fence"),
              tenant_id: episode.fetch("tenant_id"),
              situation_id: snapshot.fetch("situation_id"),
              situation_version: snapshot.fetch("situation_version"),
              risk_ceiling: episode.fetch("risk_ceiling")
            },
            snapshot:
          )
        }
      else
        pressure = state.fetch(:snapshot).fetch("facts", {}).fetch("pressure", 0.0)
        memory = state.fetch(:situation_memory)
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 3, output_tokens: 1}})
        {
          primary_hypothesis: "bearing wear risk",
          confidence: pressure < 0.5 ? 0.3 : 0.9,
          summary: "pressure #{pressure}",
          facts_used: [
            {"pressure" => pressure},
            *memory.map { |entry| {"memory" => entry.fetch("digest")} }
          ],
          alternatives: []
        }
      end
    end
    edge Tamoz::START, :analyze
    edge :analyze, Tamoz::END
  end
  graph.compile(checkpointer: checkpointer)
end

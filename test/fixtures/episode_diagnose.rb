# frozen_string_literal: true

# The bin/tamoz-stream-worker graph fixture: a DIAGNOSE episode that reads
# the verified snapshot's facts and proposes a decision. The launcher
# convention is build_episode_app(checkpointer) -> a compiled app.

def build_episode_app(checkpointer)
  graph = Tamoz.graph(name: "episode-diagnose", version: "1") do
    state :episode, default: {}
    state :snapshot, default: {}
    state :primary_hypothesis, default: nil
    state :confidence, default: nil
    state :summary, default: nil
    state :facts_used, default: []
    state :alternatives, default: []
    node(:analyze, implementation_name: "episode.analyze", version: "1") do |state, context|
      pressure = state.fetch(:snapshot).fetch("facts", {}).fetch("pressure", 0.0)
      context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
      context.emit(:model_completed,
                   {ordinal: 0, usage: {input_tokens: 3, output_tokens: 1}})
      {
        primary_hypothesis: "bearing wear risk",
        confidence: pressure < 0.5 ? 0.3 : 0.9,
        summary: "pressure #{pressure}",
        facts_used: [{"pressure" => pressure}],
        alternatives: []
      }
    end
    edge Tamoz::START, :analyze
    edge :analyze, Tamoz::END
  end
  graph.compile(checkpointer: checkpointer)
end

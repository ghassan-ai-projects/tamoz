# frozen_string_literal: true

require_relative "test_helper"

class GraphImmutableRecallChannelsTest < Minitest::Test
  def test_the_recall_node_writes_the_memory_channels
    app = Tamoz.graph(name: "recall-channels", version: "1") do
      state :situation_memory, default: []
      state :memory_record_digests, default: []
      node(:recall, implementation_name: "test.recall", version: "1") do |_state, _context|
        {
          situation_memory: [{"digest" => "sha256:#{"a" * 64}", "statement" => "prior"}],
          memory_record_digests: ["sha256:#{"a" * 64}"]
        }
      end
      edge Tamoz::START, :recall
      edge :recall, Tamoz::END
    end.compile
    manager = app.__send__(:state_manager)

    initial = manager.initial({}, remaining_steps: app.limits.max_steps)
    assert_equal [], initial.fetch(:situation_memory),
                 "the runner no longer seeds the recall channels"
    update = manager.normalize_update(
      {
        situation_memory: [{"digest" => "sha256:#{"a" * 64}", "statement" => "prior"}],
        memory_record_digests: ["sha256:#{"a" * 64}"]
      }
    )
    assert_equal ["sha256:#{"a" * 64}"], update.fetch(:memory_record_digests)
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class GraphImmutableRecallChannelsTest < Minitest::Test
  def test_immutable_recall_channel_accepts_initial_input_but_rejects_node_updates
    app = Tamoz.graph(name: "immutable-recall", version: "1") do
      state :situation_memory, default: [], immutable: true
      state :memory_record_digests, default: [], immutable: true
      node(:finish) { |_state, _context| {situation_memory: [{"digest" => "tampered"}]} }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end.compile
    manager = app.__send__(:state_manager)

    assert_equal [], manager.initial(
      {situation_memory: []}, remaining_steps: app.limits.max_steps
    ).fetch(:situation_memory)
    assert_raises(Tamoz::InvalidUpdateError) do
      manager.normalize_update({situation_memory: [{"digest" => "tampered"}]})
    end
  end
end

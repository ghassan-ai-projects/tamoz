# frozen_string_literal: true

module ChatAttachmentHelpers
  def harness_with(model)
    Tamoz::ExperienceSim::Harness.new(model_factory: ->(**) { model }, routing: :work)
  end

  def user_messages(model)
    JSON.parse(model.requests.first).fetch('messages').select { |message| message['role'] == 'user' }
                                                      .map { |message| message['content'] }
  end

  def last_turn(model)
    JSON.parse(model.requests.last).fetch('messages').select { |message| message['role'] == 'user' }
                                                     .map { |message| message['content'] }.last(2)
  end
end

# frozen_string_literal: true

# One scenario per expectation in docs/telegram-chat/GOAL.md; checks read observations, never wording.
module TelegramChatScenarios
  module_function

  # A plain answer carries no system caveat; the caveats are for work that failed or went unchecked.
  def plain(eval, scenario, turns)
    caveats = [Tamoz::Agent::ChatReply::UNVERIFIED, Tamoz::Agent::ChatReply::GAVE_UP, Tamoz::Agent::ChatReply::FAILED]
    noisy = turns.select { |turn| caveats.any? { |caveat| turn.reply.include?(caveat) } }
    eval.check(scenario, 'plain answer, no system caveat', noisy.empty?, noisy.map(&:text).join(' | '))
  end

  def all = %w[greet memory reset arabic workspace_read create_file long help burst photo stranger provider_down]

  def greet(eval)
    turn = eval.turn(eval.fresh_user, 'hi')
    eval.check('greet', 'replied', !turn.reply.strip.empty?)
    eval.check('greet', 'one message bubble', turn.sends <= 1, "#{turn.sends} messages")
    eval.check('greet', 'typing indicator shown', turn.typing.positive?)
    eval.check('greet', 'answer within 15s', turn.answer_s <= 15, format('%.1fs', turn.answer_s))
    eval.hygiene('greet', [turn])
    plain(eval, 'greet', [turn])
  end

  def memory(eval)
    user = eval.fresh_user
    told = eval.turn(user, 'My name is Ghassan and my favourite colour is teal.')
    asked = eval.turn(user, 'What is my favourite colour? Answer in one word.')
    eval.check('memory', 'recalls a fact from the previous turn', asked.reply =~ /teal/i, asked.reply)
    eval.check('memory', 'one bubble per reply', [told, asked].all? { |turn| turn.sends <= 1 },
               [told, asked].map(&:sends).inspect)
    eval.hygiene('memory', [told, asked])
    plain(eval, 'memory', [told, asked])
  end

  def reset(eval)
    user = eval.fresh_user
    told = eval.turn(user, 'Remember this: my favourite fruit is mango.')
    fresh = eval.turn(user, '/new')
    asked = eval.turn(user, 'What is my favourite fruit? If you do not know, say you do not know.')
    eval.check('reset', '/new acknowledged', fresh.sends.positive?, fresh.reply)
    answer = asked.reply
    eval.check('reset', 'forgets after /new', answer.match?(/\S/) && !answer.match?(/mango/i), answer)
    settles = eval.settles(user)
    eval.check('reset', 'still answers after /new', settles.last == 'answer', settles.inspect)
    eval.hygiene('reset', [told, fresh, asked])
  end

  def arabic(eval)
    turn = eval.turn(eval.fresh_user, 'مرحبا، كيف حالك؟')
    eval.check('arabic', 'replies in Arabic', turn.reply =~ /\p{Arabic}{3,}/, turn.reply)
    eval.hygiene('arabic', [turn])
    plain(eval, 'arabic', [turn])
  end

  def workspace_read(eval)
    turn = eval.turn(eval.fresh_user, 'What is the project codename written in the README?')
    eval.check('workspace_read', 'answers from the workspace file', turn.reply.include?('BLUE-HERON-42'), turn.reply)
    eval.check('workspace_read', 'answer within 45s', turn.answer_s <= 45, format('%.1fs', turn.answer_s))
    eval.hygiene('workspace_read', [turn])
    plain(eval, 'workspace_read', [turn])
  end

  def create_file(eval)
    user = eval.fresh_user
    turns = [eval.turn(user, 'Create a file named notes.txt in the workspace containing exactly the word: hello')]
    approve = turns.last.button('approve:')
    turns << eval.turn(user, tap: approve) if approve
    eval.check('create_file', 'file really created', eval.workspace_text('notes.txt').include?('hello'))
    eval.check('create_file', 'user told the outcome', !turns.last.reply.strip.empty?, turns.last.reply)
    eval.check('create_file', 'says no check verified it', turns.last.reply.include?(Tamoz::Agent::ChatReply::UNVERIFIED),
               turns.last.reply)
    eval.hygiene('create_file', turns)
  end

  def long(eval)
    turn = eval.turn(eval.fresh_user, 'Count from 1 to 1200, one number per line, nothing else.')
    numbers = turn.reply.scan(/^\d+$/).map(&:to_i)
    eval.check('long', 'whole answer delivered', (1..1200).all? { |n| numbers.include?(n) },
               "#{numbers.uniq.length} of 1200 numbers, #{turn.reply.length} chars in #{turn.sends} messages")
    eval.hygiene('long', [turn])
  end

  def help(eval)
    turn = eval.turn(eval.fresh_user, '/help')
    eval.check('help', 'lists /new', turn.reply.include?('/new'), turn.reply)
    eval.check('help', 'answer within 5s', turn.first_reply_s.to_f <= 5,
               format('%.1fs', turn.first_reply_s.to_f))
  end

  def burst(eval)
    turn = eval.burst(eval.fresh_user, ['What is 2+2? Reply with the number only.',
                                        'What is the capital of France? One word.'])
    eval.check('burst', 'both messages answered', turn.reply =~ /\b4\b/ && turn.reply =~ /Paris/i, turn.reply)
    eval.hygiene('burst', [turn])
  end

  def photo(eval)
    turn = eval.turn(eval.fresh_user, photo: true, timeout: 20)
    eval.check('photo', 'non-text gets a reply', !turn.reply.strip.empty?, turn.reply)
  end

  def stranger(eval)
    stranger = TelegramChatEval::STRANGER
    eval.fake.say(stranger, 'hi, who are you?')
    sleep 0.3 while eval.inbound_dispositions(stranger).empty? && eval.ensure_children_alive
    seen = eval.inbound_dispositions(stranger)
    eval.check('stranger', 'stranger never reaches the model', seen.any? && seen.none?('request'), seen.inspect)
  end

  # Runs last: it restarts the worker with a key the provider refuses.
  def provider_down(eval)
    eval.restart_worker(eval.provider_key_name => 'sk-invalid')
    turn = eval.turn(eval.fresh_user, 'hi', timeout: 60)
    eval.check('provider_down', 'user told within 30s', turn.answer_s <= 30, format('%.1fs', turn.answer_s))
    eval.check('provider_down', 'names the model provider as the problem',
               turn.reply =~ /provider|API key|model service/i, turn.reply)
    eval.hygiene('provider_down', [turn])
  end
end

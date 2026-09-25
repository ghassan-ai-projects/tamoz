# frozen_string_literal: true

# One scenario per expectation in docs/telegram-chat/GOAL.md; checks read observations, never wording.
# rubocop:disable Metrics/ModuleLength -- one scenario per bar row; splitting the
#   module would hide the row-to-check mapping this file exists to make visible.
module TelegramChatScenarios
  module_function

  # A plain answer carries no system caveat; the caveats are for work that failed or went unchecked.
  def plain(eval, scenario, turns)
    caveats = [Tamoz::Agent::ChatReply::UNVERIFIED, Tamoz::Agent::ChatReply::GAVE_UP, Tamoz::Agent::ChatReply::FAILED]
    noisy = turns.select { |turn| caveats.any? { |caveat| turn.reply.include?(caveat) } }
    eval.check(scenario, 'plain answer, no system caveat', noisy.empty?, noisy.map(&:text).join(' | '))
  end

  def all
    %w[setup returning_owner greet memory reset arabic formatting workspace_read create_file deny long help
       status_cancel burst photo stranger long_conversation restart provider_down]
  end

  # S1: the one documented command wrote a runnable runtime; every later scenario
  # runs on it, so the chat checks double as evidence the command's output works.
  def setup(eval)
    written = eval.setup
    check_setup_identity(eval, written)
    check_setup_pairing(eval, written)
  end

  def check_setup_identity(eval, written)
    channel = written[:channel]
    eval.check('setup', 'the documented command exited 0', written[:status].zero?, written[:err])
    eval.check('setup', 'it pinned the authenticated bot id',
               channel['expected_bot_id'] == eval.fake.bot_id, channel['expected_bot_id'].inspect)
  end

  def check_setup_pairing(eval, written)
    paired = Array(written[:channel].dig('admission', 'correspondents'))
    eval.check('setup', 'it paired the owner who messaged the bot', paired.include?("telegram:user:#{eval.owner}"),
               "#{paired.inspect} #{written[:out].lines.last(3).join.strip}")
    eval.check('setup', 'it wrote the workspace profile', File.exist?(written[:profile]), written[:profile])
  end

  # The owner's own chat, which on a lived-in runtime already has history bound to an older profile:
  # the first message after setup must get a real answer, not "something went wrong".
  def returning_owner(eval)
    turn = eval.turn(eval.owner, 'hi')
    eval.check('returning_owner', 'the owner gets a real answer',
               !turn.reply.include?(Tamoz::Agent::ChatReply::FAILED) && turn.reply.match?(/\p{L}{2}/), turn.reply)
    eval.hygiene('returning_owner', [turn])
  end

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

  # W2 / owner decision D1: the write must really ask, the paired owner must be
  # able to Approve from the phone, and only then is the file on disk. The
  # resumed turn runs the whole work loop again, so the tap gets its own budget.
  def create_file(eval)
    user = eval.fresh_user
    asked = eval.turn(user, 'Create a file named notes.txt in the workspace containing exactly the word: hello')
    approve = asked.button('approve:')
    check_write_prompt(eval, 'create_file', asked, approve, %w[notes.txt hello])
    eval.check('create_file', 'nothing is written before approval',
               !eval.workspace_text('notes.txt').include?('hello'), 'file exists before the tap')
    turns = [asked]
    turns << eval.turn(user, tap: approve, timeout: 180) if approve
    check_created_file(eval, turns.last, approve)
    eval.hygiene('create_file', turns)
  end

  # W3: the person deciding sees what will change, on a button they can press.
  def check_write_prompt(eval, scenario, turn, button, shown)
    eval.check(scenario, 'the write asks and offers the button on the phone', !button.nil?, turn.reply)
    eval.check(scenario, 'the prompt names the file and shows the content',
               shown.all? { |text| turn.reply.include?(text) }, turn.reply)
  end

  def check_created_file(eval, turn, approve)
    reply = turn.reply
    eval.check('create_file', 'file really created', eval.workspace_text('notes.txt').include?('hello'))
    eval.check('create_file', 'the reply is the outcome, not just the approval',
               reply.strip != 'Approved.' && !reply.strip.empty?, reply)
    eval.check('create_file', 'says no check verified it', reply.include?(Tamoz::Agent::ChatReply::UNVERIFIED), reply)
    eval.check('create_file', 'the buttons go away after the tap', approve && !eval.buttons?(approve.first))
  end

  def deny(eval)
    user = eval.fresh_user
    asked = eval.turn(user, 'Create a file named secret.txt in the workspace containing exactly: nope')
    deny = asked.button('deny:')
    check_write_prompt(eval, 'deny', asked, deny, %w[secret.txt nope])
    return eval.hygiene('deny', [asked]) unless deny

    denied = eval.turn(user, tap: deny, timeout: 60)
    check_denied(eval, eval.settles(user), denied, deny)
    eval.hygiene('deny', [asked, denied])
  end

  def check_denied(eval, settles, denied, deny)
    eval.check('deny', 'nothing is written', eval.workspace_text('secret.txt').empty?)
    eval.check('deny', 'the user is told it was not done', !denied.reply.strip.empty?, denied.reply)
    eval.check('deny', 'the buttons go away after the tap', !eval.buttons?(deny.first))
    eval.check('deny', 'the request is closed, not left waiting', settles.last != 'admitted', settles.inspect)
  end

  # C7: what the model writes as Markdown shows as formatting on the phone, not as symbols.
  def formatting(eval)
    turn = eval.turn(eval.fresh_user, 'Show me a tiny Ruby snippet that reverses a string, ' \
                                      'and put the most important word of your explanation in bold.')
    raw = turn.reply.scan(/\*\*|```|`/).uniq
    eval.check('formatting', 'no raw Markdown symbols on screen', raw.empty?, "#{raw.join(' ')} in #{turn.reply}")
    eval.check('formatting', 'the snippet is shown as code',
               turn.calls.any? { |call| call.params['text'].to_s.match?(/<(pre|code)\b/) }, turn.reply)
    eval.hygiene('formatting', [turn])
  end

  # C8: /status tells working apart from idle, and /cancel really stops the work.
  def status_cancel(eval)
    user = eval.fresh_user
    idle = eval.turn(user, '/status', timeout: 20)
    start_long_task(eval, user)
    busy = eval.command(user, '/status')
    eval.check('status_cancel', '/status tells working apart from idle', busy.reply != idle.reply,
               "idle: #{idle.reply} / busy: #{busy.reply}")
    cancel = eval.command(user, '/cancel')
    after = eval.await(user, '(after /cancel)', since: cancel.settled_at, timeout: 90)
    check_cancelled(eval, eval.settles(user), cancel, after)
    eval.hygiene('status_cancel', [idle, busy, cancel, after])
  end

  def start_long_task(eval, user)
    started = Time.now.to_f
    eval.say(user, 'Write a 1500-word story about a lighthouse keeper, as one message.')
    eval.wait_for('the story to start', timeout: 30) { eval.fake.calls(since: started, chat: user).any? }
  end

  def check_cancelled(eval, settles, cancel, after)
    eval.check('status_cancel', '/cancel is acknowledged', !cancel.reply.strip.empty?, cancel.reply)
    eval.check('status_cancel', 'the work is stopped', settles.include?('stopped'), settles.inspect)
    eval.check('status_cancel', 'the story never arrives', after.reply.length < 1000, "#{after.reply.length} chars")
    eval.check('status_cancel', 'stopped within 30s', after.answer_s <= 30, format('%.1fs', after.answer_s))
  end

  # R5: a real chat keeps going. Long multi-byte replies pile up in the history every later
  # message carries, past the history's line and size limits; every message still gets an answer.
  def long_conversation(eval)
    user = eval.fresh_user
    turns = [eval.turn(user, 'اشرح لي بالتفصيل، في ثلاث فقرات طويلة مع رموز تعبيرية، كيف تعمل الطاقة الشمسية ☀️')]
    turns += (1..13).map { |index| eval.turn(user, "Follow-up #{index}: add one more short fact, one sentence.") }
    answered = turns.count { |turn| !turn.reply.strip.empty? && !turn.reply.include?(Tamoz::Agent::ChatReply::FAILED) }
    eval.check('long_conversation', 'all 14 messages answered', answered == turns.length,
               "#{answered}/#{turns.length}; last: #{turns.last.reply}")
    eval.check('long_conversation', 'the bot stayed up', eval.alive?, 'a process exited')
    eval.hygiene('long_conversation', turns)
  end

  # R3: a restart loses neither the conversation nor a message sent while the bot was down.
  def restart(eval)
    user = eval.fresh_user
    told = eval.turn(user, 'Please remember my locker number: 4417.')
    asked = ask_while_down(eval, user, 'What is my locker number? Just the number.')
    eval.check('restart', 'the message sent while down is answered', !asked.reply.strip.empty?, asked.reply)
    eval.check('restart', 'the conversation survives the restart', asked.reply.include?('4417'), asked.reply)
    eval.hygiene('restart', [told, asked])
  end

  def ask_while_down(eval, user, text)
    eval.stop
    sent = Time.now.to_f
    eval.say(user, text)
    sleep 2
    eval.start
    eval.await(user, "#{text} (sent while the bot was down)", since: sent)
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
    eval.check('help', 'lists /help', turn.reply.include?('/help'), turn.reply)
    eval.check('help', 'answer within 5s', turn.first_reply_s.to_f <= 5,
               format('%.1fs', turn.first_reply_s.to_f))
    eval.hygiene('help', [turn])
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
    eval.hygiene('photo', [turn])
  end

  def stranger(eval)
    stranger = TelegramChatEval::STRANGER
    eval.fake.say(stranger, 'hi, who are you?')
    wait_for_disposition(eval, stranger)
    seen = eval.inbound_dispositions(stranger)
    eval.check('stranger', 'stranger never reaches the model', seen.any? && seen.none?('request'), seen.inspect)
    check_no_reply(eval, stranger)
  end

  def wait_for_disposition(eval, stranger)
    deadline = Time.now + 15
    sleep 0.3 while eval.inbound_dispositions(stranger).empty? && Time.now < deadline && eval.ensure_children_alive
  end

  def check_no_reply(eval, stranger)
    calls = eval.fake.calls(chat: stranger)
    eval.check('stranger', 'stranger gets no reply', calls.none? { |call| call.name == 'sendMessage' },
               calls.map(&:name).inspect)
  end

  # Runs last. A key the provider refuses is named by `start` before anything runs; a key that stops
  # working while the bot runs (revoked, out of credit) is named in the chat.
  def provider_down(eval)
    eval.stop
    refused = eval.start_with_refused_key
    eval.check('provider_down', 'start refuses a rejected key within 30s',
               refused[:status] != 0 && refused[:seconds] <= 30, format('exit %<status>s in %<seconds>.1fs', refused))
    eval.check('provider_down', 'start names the key it tried', refused[:out].include?('OPENROUTER_API_KEY'),
               refused[:out].lines.last(2).join.strip)
    eval.run_with_revoked_key
    check_revoked_key_reply(eval, eval.turn(eval.fresh_user, 'hi', timeout: 60))
  end

  def check_revoked_key_reply(eval, turn)
    eval.check('provider_down', 'the chat is told within 30s', turn.answer_s <= 30, format('%.1fs', turn.answer_s))
    eval.check('provider_down', 'names the model provider as the problem',
               turn.reply =~ /provider|API key|model service/i, turn.reply)
    eval.hygiene('provider_down', [turn])
  end
end
# rubocop:enable Metrics/ModuleLength

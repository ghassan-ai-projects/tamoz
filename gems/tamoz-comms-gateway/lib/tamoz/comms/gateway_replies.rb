# frozen_string_literal: true

module Tamoz
  module Comms
    # What the gateway says to a correspondent, and the refusals it records: one place for every word.
    class Gateway
      HELP_REPLY = "Just send me a message. /new starts a fresh conversation, /status shows what I'm doing, " \
                   '/cancel stops it. /help more lists every command.'
      HELP_MORE_REPLY = 'Commands: /help [more], /status [r<reference>] [--diagnostic], /new, ' \
                        '/cancel [r<reference>], /redirect r<reference> <new task>, /whoami, ' \
                        '/start <pairing code>, /answer r<reference> <answer>, /reset, /compact, /usage, ' \
                        '/context, /think <low|medium|high>, /verbose <quiet|normal|detailed>, ' \
                        '/research <question> (a cited report; you see the plan first). ' \
                        'Commands are controls, not task text.'
      HELP_USAGE_REPLY = 'Usage: /help [more]'
      RESEARCH_USAGE_REPLY = 'Usage: /research <question>. I show you a research plan first, then write a cited report.'
      NO_WORK_REPLY = 'Nothing is running right now.'
      STATUS_USAGE_REPLY = 'Usage: /status [r<reference>] [--diagnostic]'
      UNKNOWN_REF_REPLY = 'No request with that reference is admitted for this conversation.'
      AMBIGUOUS_REF_REPLY = 'That reference matches more than one request; use the full reference.'
      NEW_CONVERSATION_REPLY = "New conversation started. I won't use earlier messages."
      UNADMITTABLE_REPLY = "Sorry, I couldn't take that message in. Please send it again, or /new to start fresh."
      SETTINGS_CHANGED_REPLY = "My settings changed since we last talked, so I've started a fresh conversation."
      NEW_CONVERSATION_UNBOUND_REPLY =
        'No conversation is bound for this channel yet; send a message first.'
      REDIRECT_USAGE_REPLY = 'Usage: /redirect r<reference> <new task>'
      ANSWER_USAGE_REPLY = 'Usage: /answer r<reference> <answer>'
      ANSWER_QUEUED_REPLY = 'Answer received; resuming the paused request.'
      ANSWER_STALE_REPLY = 'That request is no longer waiting for a clarification answer.'
      ANSWER_WRONG_CORRESPONDENT_REPLY = 'That clarification answer cannot be used from this correspondent.'
      ANSWER_UNQUEUED_REPLY = 'Answer could not be queued; try again while the request is paused.'
      START_USAGE_REPLY = 'Usage: /start <pairing code>'
      START_WAITING_REPLY =
        'That code matches a pending pairing request. Waiting for operator approval.'
      START_NO_MATCH_REPLY = "That code doesn't match a pending pairing request."
      START_PAIRED_REPLY = "Hi! I'm Tamoz. Just send me a message; /help lists the commands.\n" \
                           'أهلاً! أنا تاموز. أرسل لي رسالة، و/help يعرض الأوامر.'
      PAIRING_PENDING_REPLY =
        "This chat isn't paired yet. Read this code to your operator for approval: "
      PAIRING_CODE_TTL_S = 86_400.0
      REDIRECT_UNQUEUED_REPLY = 'Redirect could not be queued; no active checkpoint is available.'
      FINISHED_REQUEST_REPLY = 'That request has already finished.'
      CANCEL_NO_WORK_REPLY = "There's nothing to stop right now."
      CANCEL_REPLY = 'Stopping…'
      CANCEL_USAGE_REPLY = 'Usage: /cancel [r<reference>]'
      CANCEL_STALE_REF_REPLY = 'That request is no longer open on this conversation.'

      CONTROLS_UNAVAILABLE_REPLY = 'Context controls are not available on this channel.'
      CONTROLS_NO_SESSION_REPLY =
        'No session state exists for this conversation yet; send a task first.'
      CONTROLS_CONFLICT_REPLY =
        'Context controls are busy right now; another writer holds this conversation. Try again.'

      CONTROL_ARGUMENT_REFUSALS = {
        'think' => 'Reasoning depth must be low, medium, or high.',
        'verbose' => 'Answer verbosity must be quiet, normal, or detailed.'
      }.freeze

      ADMISSION_REFUSALS = {
        integrity_conflict: ['quarantined',
                             'This update conflicts with an earlier message carrying the same identity. ' \
                             'An operator can review it.'],
        open_request_limit: ['rejected', 'This channel has too much open work right now; try again later.'],
        inbound_too_large: ['rejected', "That message exceeds this channel's size limit."],
        capacity_refused: ['rejected', 'The channel is at capacity; try again later.'],
        attachment_too_large: ['rejected', 'That file is too large for me; the limit is ' \
                                           "#{Attachments::MAX_ATTACHMENT_BYTES / 1_000_000} MB."],
        image_too_large: ['rejected', 'That image is too large for me; the limit is ' \
                                      "#{Attachments::MAX_IMAGE_BYTES / 1_000_000} MB."],
        audio_too_large: ['rejected', 'That recording is too large for me; the limit is ' \
                                      "#{Attachments::MAX_AUDIO_BYTES / 1_000_000} MB."],
        voice_too_long: ['rejected', 'That voice message is too long for me; the limit is ' \
                                     "#{Attachments::MAX_VOICE_SECONDS / 60} minutes."],
        attachment_empty: ['rejected', 'That file is empty.'],
        attachment_unavailable: ['rejected', "I couldn't download that file. Please send it again."],
        attachments_unavailable: ['rejected', "This channel isn't set up to receive files."]
      }.freeze
    end
  end
end

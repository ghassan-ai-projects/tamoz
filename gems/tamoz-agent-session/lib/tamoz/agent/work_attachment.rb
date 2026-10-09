# frozen_string_literal: true

module Tamoz
  module Agent
    # The file a channel turn arrived with, as the text the work loop opens with or the reason it could not be read.
    class WorkAttachment
      MAX_CHARACTERS = 24_000
      MAX_IMAGE_BYTES = 5_000_000
      MAX_NAME_CHARACTERS = 60
      MARKER = /<<<|>>>/
      AUDIO_TYPES = { 'audio/ogg' => '.ogg', 'audio/mpeg' => '.mp3', 'audio/mp4' => '.m4a', 'audio/x-m4a' => '.m4a',
                      'audio/wav' => '.wav', 'audio/x-wav' => '.wav', 'audio/webm' => '.webm',
                      'audio/flac' => '.flac' }.freeze
      IMAGE_TYPES = { "\x89PNG".b => 'image/png', "\xFF\xD8\xFF".b => 'image/jpeg', 'GIF8'.b => 'image/gif' }.freeze

      Reading = Data.define(:material, :event, :request, :task)
      Read = Data.define(:result, :call)

      def initialize(configuration:, effects:)
        @configuration = configuration
        @effects = effects
      end

      def read(attachment, window:, context:)
        read = read_of(attachment, context)
        result = read.result
        limit = [MAX_CHARACTERS, window].min
        event = event(attachment, result, limit)
        request = read.call && request_trace(read.call, attachment.fetch('kind'))
        if result.outcome == :read && attachment.fetch('kind') == 'voice'
          return Reading.new(material: labels.fetch('voice'), event:, request:, task: result.text[0, limit])
        end

        material = result.outcome == :read ? material(attachment, result, limit) : unreadable(attachment, result)
        Reading.new(material:, event:, request:, task: nil)
      end

      private

      def read_of(attachment, context)
        bytes = @configuration.artifact_store&.resolve(attachment.fetch('digest'))&.fetch('bytes')
        return Read.new(AttachmentText::Result.failed(:missing), nil) unless bytes

        case attachment.fetch('kind')
        when 'document' then Read.new(AttachmentText.read(bytes), nil)
        when 'image' then image(bytes.b, context)
        else speech(bytes.b, attachment, context)
        end
      end

      def image(bytes, context)
        type = image_type(bytes)
        unless type && bytes.bytesize <= MAX_IMAGE_BYTES
          return Read.new(AttachmentText::Result.failed(:image_format), nil)
        end

        call = @effects.converse(context, stage: :attachment_image, messages: image_messages(bytes, type), tools: [],
                                          iteration: 0)
        journaled(call, 'content', unread: :image_unread, silent: :image_unread)
      end

      def speech(bytes, attachment, context)
        return Read.new(AttachmentText::Result.failed(:voice_not_set_up), nil) unless @configuration.transcriber

        type = attachment['media_type'] || 'audio/ogg'
        call = @effects.transcribe(context, audio: bytes, filename: "audio#{AUDIO_TYPES.fetch(type, '')}",
                                            media_type: type)
        journaled(call, 'text', unread: :voice_unread, silent: :heard_nothing)
      end

      def journaled(call, field, unread:, silent:)
        raise LeaseLostError, "another owner still holds effect #{call.effect_key}" if call.status == :wait
        return Read.new(AttachmentText::Result.failed(unread), call) unless call.status == :succeeded

        text = call.value.fetch(field).strip
        Read.new(text.empty? ? AttachmentText::Result.failed(silent) : AttachmentText::Result.read(text), call)
      end

      def request_trace(call, kind)
        usage = call.status == :succeeded ? ContextEngine::Usage.from_provider(call.value['usage'])&.to_h : nil
        { 'event' => 'request', 'stage' => kind == 'image' ? 'attachment_image' : 'transcribe',
          'status' => call.status.to_s, 'usage' => usage }
      end

      def image_type(bytes)
        return 'image/webp' if bytes.byteslice(0, 4) == 'RIFF'.b && bytes.byteslice(8, 4) == 'WEBP'.b

        IMAGE_TYPES.find { |magic, _type| bytes.start_with?(magic) }&.last
      end

      def image_messages(bytes, type)
        [{ 'role' => 'user', 'content' => [
          { 'type' => 'text', 'text' => labels.fetch('image_instruction') },
          { 'type' => 'image_url', 'image_url' => { 'url' => "data:#{type};base64,#{[bytes].pack('m0')}" } }
        ] }]
      end

      def material(attachment, result, limit)
        text = result.text
        note = result.pages ? pages_note(result.pages) : ''
        note += format(labels.fetch('truncated'), shown: limit) if text.length > limit
        format(labels.fetch('material'), what: what(attachment), name: name(attachment), note:,
                                         content: framed(text[0, limit]))
      end

      # Content can never close its own frame.
      def framed(content) = content.gsub(MARKER) { |run| run.tr('<>', '‹›') }

      def pages_note(pages)
        format(labels.fetch(pages >= AttachmentText::PDF_PAGES ? 'pages_cut' : 'pages'), pages:)
      end

      def unreadable(attachment, result)
        format(labels.fetch('unreadable'), what: what(attachment), name: name(attachment),
                                           reason: labels.fetch('reasons').fetch(result.outcome.to_s))
      end

      def event(attachment, result, limit)
        { 'event' => 'attachment', 'kind' => attachment.fetch('kind'), 'outcome' => result.outcome.to_s,
          'characters' => result.text && [result.text.length, limit].min, 'pages' => result.pages }.compact
      end

      def what(attachment)
        kind = attachment['media_type'] == 'application/pdf' ? 'pdf' : attachment.fetch('kind')
        labels.fetch('what').fetch(kind)
      end

      # A sender's file name sits in the instruction sentence, so only plain name characters survive.
      def name(attachment)
        cleaned = attachment['name'].to_s.gsub(/[^\p{L}\p{N} ._-]/, '').strip[0, MAX_NAME_CHARACTERS]
        cleaned.empty? ? '' : " \"#{cleaned}\""
      end

      def labels = Harness::PromptPack.attachment_text
    end
  end
end

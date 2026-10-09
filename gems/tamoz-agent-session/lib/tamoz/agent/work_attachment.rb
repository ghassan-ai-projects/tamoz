# frozen_string_literal: true

module Tamoz
  module Agent
    # The file a channel turn arrived with, read into the text the work loop opens with — or the reason it could not
    # be read, so the model can say so in the conversation's language.
    class WorkAttachment
      MAX_CHARACTERS = 24_000
      MARKER = /<<<|>>>/
      MAX_IMAGE_BYTES = 5_000_000
      IMAGE_TYPES = { "\x89PNG".b => 'image/png', "\xFF\xD8\xFF".b => 'image/jpeg', 'GIF8'.b => 'image/gif' }.freeze

      # `request` is the trace entry of the model call an image read cost, so turn usage counts it.
      Reading = Data.define(:material, :event, :request)

      def initialize(configuration:, effects:)
        @configuration = configuration
        @effects = effects
      end

      # `window` is the route's context window in tokens; the material is capped at that many characters, which is at
      # most a quarter of it for Latin text and more for denser scripts.
      def read(attachment, window:, context:)
        result, call = text_of(attachment, context)
        limit = [MAX_CHARACTERS, window].min
        material = result.outcome == :read ? material(attachment, result, limit) : unreadable(attachment, result)
        Reading.new(material:, event: event(attachment, result, limit), request: call && request_trace(call))
      end

      private

      def text_of(attachment, context)
        bytes = stored_bytes(attachment.fetch('digest'))
        return [AttachmentText::Result.new(:missing, nil, nil)] unless bytes

        case attachment.fetch('kind')
        when 'document' then [AttachmentText.read(bytes)]
        when 'image' then image(bytes.b, context)
        else [AttachmentText::Result.new(:unsupported_format, nil, nil)]
        end
      end

      # One journaled call to the configured model with the image attached: its text verbatim, then what it shows.
      def image(bytes, context)
        type = image_type(bytes)
        return [AttachmentText::Result.new(:image_format, nil, nil)] unless type && bytes.bytesize <= MAX_IMAGE_BYTES

        call = @effects.converse(context, stage: :attachment_image, messages: image_messages(bytes, type), tools: [],
                                          iteration: 0)
        raise LeaseLostError, "another owner still holds effect #{call.effect_key}" if call.status == :wait

        text = call.status == :succeeded ? call.value.fetch('content').strip : ''
        [text.empty? ? AttachmentText::Result.new(:image_unread, nil, nil) : AttachmentText::Result.new(:read, text, nil),
         call]
      end

      def request_trace(call)
        usage = call.status == :succeeded ? ContextEngine::Usage.from_provider(call.value['usage'])&.to_h : nil
        { 'event' => 'request', 'stage' => 'attachment_image', 'status' => call.status.to_s, 'usage' => usage }
      end

      # The bytes decide the type, never the sender's label; a WebP is RIFF....WEBP.
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

      # A missing row reads as nothing; a store failure or a row that no longer matches its digest fails the turn.
      def stored_bytes(digest) = @configuration.artifact_store&.resolve(digest)&.fetch('bytes')

      def material(attachment, result, limit)
        text = result.text
        note = result.pages ? pages_note(result.pages) : ''
        note += format(labels.fetch('truncated'), shown: limit) if text.length > limit
        format(labels.fetch('material'), what: what(attachment), name: name(attachment), note:,
                                         content: framed(text[0, limit]))
      end

      # The content can never close its own frame: marker runs inside it are turned into look-alike quotes.
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

      def name(attachment)
        cleaned = attachment['name'].to_s.gsub(/[[:cntrl:]"<>]/, '').strip
        cleaned.empty? ? '' : " \"#{cleaned}\""
      end

      def labels = Harness::PromptPack.attachment_text
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    # The file a channel turn arrived with, read into the text the work loop opens with — or the reason it could not
    # be read, so the model can say so in the conversation's language.
    class WorkAttachment
      MAX_CHARACTERS = 24_000
      MARKER = /<<<|>>>/

      Reading = Data.define(:material, :event)

      def initialize(configuration:)
        @configuration = configuration
      end

      # `window` is the route's context window in tokens; the material is capped at that many characters, which is at
      # most a quarter of it for Latin text and more for denser scripts.
      def read(attachment, window:)
        result = text_of(attachment)
        limit = [MAX_CHARACTERS, window].min
        material = result.outcome == :read ? material(attachment, result, limit) : unreadable(attachment, result)
        Reading.new(material:, event: event(attachment, result, limit))
      end

      private

      def text_of(attachment)
        bytes = stored_bytes(attachment.fetch('digest'))
        return AttachmentText::Result.new(:missing, nil, nil) unless bytes
        return AttachmentText.read(bytes) if attachment.fetch('kind') == 'document'

        AttachmentText::Result.new(:unsupported_format, nil, nil)
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

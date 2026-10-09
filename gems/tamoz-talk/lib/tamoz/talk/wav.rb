# frozen_string_literal: true

module Tamoz
  module Talk
    # The one audio shape the page sends: 16 kHz, 16-bit, mono PCM WAV.
    module Wav
      SAMPLE_RATE = 16_000
      MAX_SECONDS = 60
      class Error < StandardError
      end

      module_function

      # @return [Float] the duration in seconds
      def duration(bytes)
        bytes = bytes.b
        raise Error, 'not a WAV file' unless bytes.byteslice(0, 4) == 'RIFF' && bytes.byteslice(8, 4) == 'WAVE'

        format, data = chunks(bytes)
        raise Error, 'the WAV file has no format or data chunk' unless format && data

        audio_format, channels, rate, _byte_rate, _align, bits = format.unpack('vvVVvv')
        raise Error, 'the audio must be 16 kHz, 16-bit, mono PCM' unless [audio_format, channels, rate, bits] ==
                                                                         [1, 1, SAMPLE_RATE, 16]

        data.bytesize / (SAMPLE_RATE * 2.0)
      end

      def chunks(bytes)
        offset = 12
        found = {}
        while offset + 8 <= bytes.bytesize
          id = bytes.byteslice(offset, 4)
          size = bytes.byteslice(offset + 4, 4).unpack1('V')
          found[id] ||= bytes.byteslice(offset + 8, size)
          offset += 8 + size + (size % 2)
        end
        [found['fmt '], found['data']]
      end
    end
  end
end

# frozen_string_literal: true

# Audio-header detection for the talk retention scan: WAV, Ogg, ID3 and MPEG frame sync.
module TalkAudio
  BITRATES = {
    [3, 3] => [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    [3, 2] => [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    [3, 1] => [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    [2, 3] => [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    [2, 2] => [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    [2, 1] => [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
  }.freeze
  RATES = { 3 => [44_100, 48_000, 32_000], 2 => [22_050, 24_000, 16_000], 0 => [11_025, 12_000, 8000] }.freeze

  module_function

  def audio_kinds(bytes)
    bytes = bytes.b
    kinds = []
    kinds << 'wav' if bytes.match?(/RIFF.{4}WAVEfmt /mn)
    kinds << 'ogg' if bytes.match?(/OggS\x00[\x00-\x07]/n)
    kinds << 'id3' if bytes.match?(/ID3[\x02-\x04][\x00-\xFE]/n)
    kinds << 'mpeg' if mpeg_frames?(bytes)
    kinds
  end

  def mpeg_frames?(bytes)
    offset = 0
    while (offset = bytes.index("\xFF".b, offset))
      length = frame_length(bytes, offset)
      return true if length && frame_length(bytes, offset + length)

      offset += 1
    end
    false
  end

  def frame_length(bytes, offset)
    return nil if offset + 4 > bytes.bytesize

    sync, b1, b2 = bytes.byteslice(offset, 3).unpack('C3')
    return nil unless sync == 0xFF && b1.allbits?(0xE0)

    header = header_fields(b1, b2)
    frame_bytes(*header) if valid_header?(*header)
  end

  def header_fields(byte1, byte2)
    [(byte1 >> 3) & 3, (byte1 >> 1) & 3, byte2 >> 4, (byte2 >> 2) & 3, (byte2 >> 1) & 1]
  end

  def valid_header?(version, layer, bitrate_index, rate_index, _padding)
    !(version == 1 || layer.zero? || [0, 15].include?(bitrate_index) || rate_index == 3)
  end

  def frame_bytes(version, layer, bitrate_index, rate_index, padding)
    bitrate = BITRATES.fetch([version == 3 ? 3 : 2, layer])[bitrate_index] * 1000
    rate = RATES.fetch(version)[rate_index]
    return ((12 * bitrate / rate) + padding) * 4 if layer == 3

    ((version == 3 || layer == 2 ? 144 : 72) * bitrate / rate) + padding
  end
end

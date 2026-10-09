# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

# The talk eval's audio: macOS `say` renderings as 16 kHz mono 16-bit WAV, calibrated pink noise, ffmpeg variants
# and mp3 → WAV. Every tool it needs is named by `missing_tools`, so a run without one is BLOCKED, never faked.
module TalkAudio
  RATE = 16_000
  TOOLS = %w[say afconvert ffmpeg ffprobe].freeze

  module_function

  def missing_tools = TOOLS.reject { |tool| system('which', tool, out: File::NULL, err: File::NULL) }

  def missing_voices(voices)
    out, = Open3.capture2('say', '-v', '?')
    voices.reject { |voice| out.match?(/^#{Regexp.escape(voice)}\s/) }
  end

  def render(text, voice:, lead_s:, trail_s:)
    Dir.mktmpdir('talk-say') do |directory|
      aiff = File.join(directory, 'say.aiff')
      wav = File.join(directory, 'say.wav')
      run!('say', '-v', voice, '-o', aiff, text)
      run!('afconvert', '-f', 'WAVE', '-d', "LEI16@#{RATE}", '-c', '1', aiff, wav)
      samples = samples(File.binread(wav))
      wav(([0] * (lead_s * RATE).round) + samples + ([0] * (trail_s * RATE).round))
    end
  end

  # PCM samples of a 16-bit WAV, whatever chunks precede `data`.
  def samples(bytes)
    offset = 12
    while offset + 8 <= bytes.bytesize
      id = bytes.byteslice(offset, 4)
      size = bytes.byteslice(offset + 4, 4).unpack1('V')
      return bytes.byteslice(offset + 8, size).unpack('s<*') if id == 'data'

      offset += 8 + size + (size & 1)
    end
    raise ArgumentError, 'no data chunk'
  end

  def wav(samples)
    data = samples.map { |sample| sample.clamp(-32_768, 32_767) }.pack('s<*')
    "RIFF#{[36 + data.bytesize].pack('V')}WAVEfmt #{[16, 1, 1, RATE, RATE * 2, 2, 16].pack('VvvVVvv')}" \
    "data#{[data.bytesize].pack('V')}".b + data
  end

  # Pink noise (Paul Kellet's filter over seeded white noise) scaled to the speech's RMS for the given SNR.
  def with_noise(bytes, snr_db:, seed:)
    speech = samples(bytes)
    voiced = speech.reject(&:zero?)
    noise = pink(speech.length, Random.new(seed))
    gain = rms(voiced) / (rms(noise) * (10**(snr_db / 20.0)))
    wav(speech.zip(noise).map { |s, n| (s + (n * gain)).round })
  end

  def pink(count, random)
    b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
    Array.new(count) do
      white = (random.rand * 2) - 1
      b0 = (0.99886 * b0) + (white * 0.0555179)
      b1 = (0.99332 * b1) + (white * 0.0750759)
      b2 = (0.96900 * b2) + (white * 0.1538520)
      b3 = (0.86650 * b3) + (white * 0.3104856)
      b4 = (0.55000 * b4) + (white * 0.5329522)
      b5 = (-0.7616 * b5) - (white * 0.0168980)
      value = b0 + b1 + b2 + b3 + b4 + b5 + b6 + (white * 0.5362)
      b6 = white * 0.115926
      value
    end
  end

  def rms(values) = Math.sqrt(values.sum { |v| v.to_f * v } / [values.length, 1].max)

  def ffmpeg_filter(bytes, filter) = through_ffmpeg(bytes, 'in.wav', ['-af', filter])

  def mp3_to_wav(bytes) = through_ffmpeg(bytes, 'in.mp3', [])

  def lavfi(source)
    Dir.mktmpdir('talk-ffmpeg') do |directory|
      out = File.join(directory, 'out.wav')
      run!('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', source, '-ar', RATE.to_s, '-ac', '1', '-c:a', 'pcm_s16le', out)
      wav(samples(File.binread(out)))
    end
  end

  def through_ffmpeg(bytes, name, args)
    Dir.mktmpdir('talk-ffmpeg') do |directory|
      input = File.join(directory, name)
      out = File.join(directory, 'out.wav')
      File.binwrite(input, bytes)
      run!('ffmpeg', '-v', 'error', '-i', input, *args, '-ar', RATE.to_s, '-ac', '1', '-c:a', 'pcm_s16le', out)
      wav(samples(File.binread(out)))
    end
  end

  def mp3?(bytes)
    out, status = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=format_name', '-of', 'csv=p=0',
                                 '-i', 'pipe:0', stdin_data: bytes, binmode: true)
    status.success? && out.strip == 'mp3'
  end

  def versions
    { 'macos' => `sw_vers -productVersion`.strip, 'ffmpeg' => `ffmpeg -version`.lines.first.to_s.strip,
      'node' => `node --version`.strip }
  rescue SystemCallError
    {}
  end

  def run!(*command)
    out, status = Open3.capture2e(*command)
    raise "#{command.first} failed: #{out[-500..] || out}" unless status.success?
  end
end

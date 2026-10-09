# frozen_string_literal: true

require 'json'
require_relative 'telegram_attachment_checks'

# The talk eval's graders: one normalizer for every compared string, WER, slots, answers, unspeakables, and the
# retention and key scans. Tables and patterns are data in test/fixtures/talk/scenarios.json.
module TalkChecks
  SPEC_PATH = File.expand_path('../fixtures/talk/scenarios.json', __dir__)
  UNITS = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
             seventeen eighteen nineteen].each_with_index.to_h
  TENS = %w[twenty thirty forty fifty sixty seventy eighty ninety].each_with_index.to_h do |word, i|
    [word, (i + 2) * 10]
  end
  ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth
                fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth].each_with_index
                                                                                 .to_h { |word, i| [word, i + 1] }
  TENS_ORDINALS = %w[twentieth thirtieth].each_with_index.to_h { |word, i| [word, (i + 2) * 10] }
  SCALES = { 'hundred' => 100, 'thousand' => 1000 }.freeze
  UNIT_WORDS = "(?:#{(UNITS.keys.first(10) + ORDINALS.keys.first(9)).join('|')})".freeze

  module_function

  def spec = @spec ||= JSON.parse(File.read(SPEC_PATH))

  def table = spec.fetch('normalizer')

  def normalize(text)
    value = text.to_s.strip.sub(/\AHeard: «(.*)»\z/m, '\1')
    value = value.unicode_normalize(:nfkc).downcase.tr('’‘', "''")
    table.fetch('units').each { |from, to| value = value.gsub(unit_pattern(from), to) }
    value = value.gsub(/(?<![\w.])([a-z][\w-]*) dot ([a-z][\w-]*)(?!\w)/, '\\1.\\2')
    value = value.gsub(/(?<=\d),(?=\d{3}\b)/, '').gsub(/(?<=[a-z])-(?=#{UNIT_WORDS}\b)/o, ' ')
    tokens = numbers(value.gsub(/[,?!;«»"()\[\]]|(?<!\p{Alnum})\.|\.(?!\p{Alnum})/, ' ¦ ').split)
    value = times(tokens.join(' '))
    tokens = value.split.filter_map { |token| punctuation(token) }
    tokens = tokens.flat_map { |token| table.fetch('contractions').fetch(token, token).split }
    tokens = tokens.map { |token| token.delete("'") }.reject(&:empty?)
    (tokens - table.fetch('fillers')).join(' ')
  end

  def tokens(text) = normalize(text).split

  def unit_pattern(from) = from.match?(/\A[a-z]/) ? /(?<![a-z])#{Regexp.escape(from)}(?![a-z])/ : from

  def wer(reference, hypothesis)
    ref = tokens(reference)
    hyp = tokens(hypothesis)
    return hyp.empty? ? 0.0 : 1.0 if ref.empty?

    distance(ref, hyp).fdiv(ref.length)
  end

  def slot?(forms, hypothesis)
    words = tokens(hypothesis)
    forms.any? do |form|
      want = tokens(form)
      !want.empty? && words.each_cons(want.length).include?(want)
    end
  end

  def answer?(groups, text) = groups.all? { |forms| slot?(forms, text) }

  def first_sentence(text) = text.to_s.strip.split(/(?<=[.!?])\s+|\n/).first.to_s

  def unspeakables(text) = spec.fetch('unspeakable').select { |pattern| text.to_s.match?(Regexp.new(pattern)) }

  # Audio headers anywhere under the runtime directory, the SQLite files and the spool included.
  def retention_hits(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }
                                                                 .filter_map do |path|
      kinds = audio_kinds(File.binread(path))
      "#{path.delete_prefix("#{directory}/")}: #{kinds.join(', ')}" unless kinds.empty?
    end
  end

  def audio_kinds(bytes)
    bytes = bytes.b
    kinds = []
    kinds << 'wav' if bytes.match?(/RIFF.{4}WAVEfmt /mn)
    kinds << 'ogg' if bytes.match?(/OggS\x00[\x00-\x07]/n)
    kinds << 'id3' if bytes.match?(/ID3[\x02-\x04][\x00-\xFE]/n)
    kinds << 'mpeg' if mpeg_frames?(bytes)
    kinds
  end

  def key_hits(bodies, keys)
    keys.select { |key| key.to_s.length >= 8 }.flat_map do |key|
      bodies.each_index.select { |index| bodies[index].to_s.b.include?(key.b) }.map { |index| "response #{index}" }
    end
  end

  def wilson(passed, runs)
    return [0.0, 1.0] if runs.zero?

    [TelegramAttachmentChecks.wilson_lower(passed, runs),
     1 - TelegramAttachmentChecks.wilson_lower(runs - passed, runs)]
  end

  def numbers(words)
    out = []
    index = 0
    while index < words.length
      value, used = number_at(words, index)
      if used.zero?
        out << words[index]
        index += 1
      else
        out << value
        index += used
      end
    end
    out.map { |word| word.sub(/\A(-?)0+(?=\d)/, '\1').sub(/\A(\d+)(?:st|nd|rd|th)\z/, '\1') }
  end

  def number_at(words, index)
    return ["-#{words[index + 1]}", 2] if %w[minus negative].include?(words[index]) && words[index + 1]&.match?(/\A\d/)

    sign = ''
    start = index
    if %w[minus negative].include?(words[index]) && cardinal(words, index + 1).last.positive?
      sign = '-'
      index += 1
    end
    value, used = cardinal(words, index)
    return ['', 0] if used.zero?

    index += used
    if words[index] == 'point' && (digit = UNITS[words[index + 1]]) && digit < 10
      decimals = []
      while (digit = UNITS[words[index + 1]]) && digit < 10
        decimals << digit
        index += 1
      end
      index += 1
      return ["#{sign}#{value}.#{decimals.join}", index - start]
    end
    ["#{sign}#{value}", index - start]
  end

  def cardinal(words, index)
    total = 0
    current = nil
    used = 0
    loop do
      word = words[index + used]
      if ORDINALS.key?(word) && (current.nil? || (current % 10).zero?)
        return [total + current.to_i + ORDINALS.fetch(word), used + 1]
      elsif TENS_ORDINALS.key?(word) && current.nil?
        return [total + TENS_ORDINALS.fetch(word), used + 1]
      elsif UNITS.key?(word) && (current.nil? || ((current % 100) >= 20 && (current % 10).zero?) || (current % 100).zero?)
        current = current.to_i + UNITS.fetch(word)
      elsif TENS.key?(word) && (current.nil? || ((current % 100).zero? && current.positive?))
        current = current.to_i + TENS.fetch(word)
      elsif SCALES.key?(word) && current
        scale = SCALES.fetch(word)
        if scale == 1000
          total += current * 1000
          current = nil
        else
          current *= 100
        end
      else
        break
      end

      used += 1
    end
    used.zero? ? [0, 0] : [total + current.to_i, used]
  end

  def times(text)
    text.gsub(/\bat (\d{1,2})[ .](\d{2})\b/) do
      ::Regexp.last_match(2).to_i < 60 && ::Regexp.last_match(1).to_i < 24 ? "at #{::Regexp.last_match(1).to_i}:#{::Regexp.last_match(2)}" : ::Regexp.last_match(0)
    end
        .gsub(/\b0(\d):(\d{2})\b/, '\1:\2')
  end

  def punctuation(token)
    token = token.gsub(/[^\p{Alnum}.:'_-]/, '')
    token = token.gsub(/(?<!\d):|:(?!\d)/, '')
    token = token.gsub(/(?<!\p{Alnum})\.|\.(?!\p{Alnum})/, '')
    token = token.gsub(/\A[-_']+|[-_']+\z/) { |edge| edge.start_with?('-') && token.match?(/\A-\d/) ? edge : '' }
    token.empty? ? nil : token
  end

  def distance(left, right)
    row = (0..right.length).to_a
    left.each_with_index do |word, i|
      previous = row.dup
      row[0] = i + 1
      right.each_with_index do |other, j|
        row[j + 1] = [previous[j + 1] + 1, row[j] + 1, previous[j] + (word == other ? 0 : 1)].min
      end
    end
    row.last
  end

  BITRATES = {
    [3, 3] => [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    [3, 2] => [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    [3, 1] => [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    [2, 3] => [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    [2, 2] => [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    [2, 1] => [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
  }.freeze
  RATES = { 3 => [44_100, 48_000, 32_000], 2 => [22_050, 24_000, 16_000], 0 => [11_025, 12_000, 8000] }.freeze

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

    b1, b2, b3 = bytes.getbyte(offset + 1), bytes.getbyte(offset + 2), bytes.getbyte(offset + 3) # rubocop:disable Style/ParallelAssignment
    return nil unless bytes.getbyte(offset) == 0xFF && (b1 & 0xE0) == 0xE0 && b3

    version = (b1 >> 3) & 3
    layer = (b1 >> 1) & 3
    bitrate_index = b2 >> 4
    rate_index = (b2 >> 2) & 3
    return nil if version == 1 || layer.zero? || [0, 15].include?(bitrate_index) || rate_index == 3

    bitrate = BITRATES.fetch([version == 3 ? 3 : 2, layer])[bitrate_index] * 1000
    rate = RATES.fetch(version)[rate_index]
    padding = (b2 >> 1) & 1
    return ((12 * bitrate / rate) + padding) * 4 if layer == 3

    ((version == 3 || layer == 2 ? 144 : 72) * bitrate / rate) + padding
  end
end

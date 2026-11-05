# frozen_string_literal: true

require 'json'
require_relative 'telegram_attachment_checks'
require_relative 'talk_numbers'
require_relative 'talk_audio'

# The talk eval's graders: one normalizer for every compared string, WER, slots, answers, unspeakables, and the
# retention and key scans. Tables and patterns are data in test/fixtures/talk/scenarios.json.
module TalkChecks
  SPEC_PATH = File.expand_path('../fixtures/talk/scenarios.json', __dir__)
  SEPARATORS = /[,?!;«»"()\[\]]|(?<!\p{Alnum})\.|\.(?!\p{Alnum})/
  DOTTED = /(?<![\w.])([a-z][\w-]*) dot ([a-z][\w-]*)(?!\w)/

  module_function

  def spec = @spec ||= JSON.parse(File.read(SPEC_PATH))

  def table = spec.fetch('normalizer')

  def normalize(text)
    tokens = punctuated_tokens(spoken_forms(text.to_s.strip.sub(/\AHeard: «(.*)»\z/m, '\1')))
    tokens = tokens.flat_map { |token| table.fetch('contractions').fetch(token, token).split }
    (tokens.map { |token| token.delete("'") }.reject(&:empty?) - table.fetch('fillers')).join(' ')
  end

  def spoken_forms(text)
    value = text.unicode_normalize(:nfkc).downcase.tr('’‘', "''")
    table.fetch('units').each { |from, to| value = value.gsub(unit_pattern(from), to) }
    value = value.gsub(DOTTED, '\\1.\\2')
    value.gsub(/(?<=\d),(?=\d{3}\b)/, '').gsub(/(?<=[a-z])-(?=#{TalkNumbers::UNIT_WORDS}\b)/o, ' ')
  end

  def punctuated_tokens(value)
    tokens = TalkNumbers.numbers(value.gsub(SEPARATORS, ' ¦ ').split)
    times(tokens.join(' ')).split.filter_map { |token| punctuation(token) }
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

  def audio_kinds(bytes) = TalkAudio.audio_kinds(bytes)

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

  def times(text)
    text.gsub(/\bat (\d{1,2})[ .](\d{2})\b/) do
      if ::Regexp.last_match(2).to_i < 60 && ::Regexp.last_match(1).to_i < 24
        "at #{::Regexp.last_match(1).to_i}:#{::Regexp.last_match(2)}"
      else
        ::Regexp.last_match(0)
      end
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
    left.each_with_index { |word, i| row = next_row(row, word, right, i) }
    row.last
  end

  def next_row(previous, word, right, index)
    row = previous.dup
    row[0] = index + 1
    right.each_with_index do |other, j|
      row[j + 1] = [previous[j + 1] + 1, row[j] + 1, previous[j] + (word == other ? 0 : 1)].min
    end
    row
  end
end

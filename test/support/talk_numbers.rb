# frozen_string_literal: true

# Spoken-number parsing for the talk normalizer: words to digits, ordinals, signs and decimals.
module TalkNumbers
  UNITS = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
             seventeen eighteen nineteen].each_with_index.to_h
  TENS = %w[twenty thirty forty fifty sixty seventy eighty ninety].each_with_index.to_h do |word, i|
    [word, (i + 2) * 10]
  end
  ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth
                fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth]
             .each_with_index.to_h { |word, i| [word, i + 1] }
  TENS_ORDINALS = %w[twentieth thirtieth].each_with_index.to_h { |word, i| [word, (i + 2) * 10] }
  SCALES = { 'hundred' => 100, 'thousand' => 1000 }.freeze
  NEGATIONS = %w[minus negative].freeze
  UNIT_WORDS = "(?:#{(UNITS.keys.first(10) + ORDINALS.keys.first(9)).join('|')})".freeze

  module_function

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
    return ["-#{words[index + 1]}", 2] if negated_digits?(words, index)

    sign = negated_number?(words, index) ? '-' : ''
    value, used = cardinal(words, index + sign.length)
    return ['', 0] if used.zero?

    fraction, length = fraction_at(words, index + sign.length + used)
    ["#{sign}#{value}#{fraction}", sign.length + used + length]
  end

  def negated_digits?(words, index)
    NEGATIONS.include?(words[index]) && words[index + 1]&.match?(/\A\d/)
  end

  def fraction_at(words, index)
    digits = decimal_digits(words, index)
    digits.empty? ? ['', 0] : [".#{digits.join}", digits.length + 1]
  end

  def negated_number?(words, index)
    NEGATIONS.include?(words[index]) && cardinal(words, index + 1).last.positive?
  end

  def decimal_digits(words, index)
    return [] unless words[index] == 'point'

    words.drop(index + 1).map { |word| UNITS[word] }.take_while { |digit| digit && digit < 10 }
  end

  def cardinal(words, index)
    total = 0
    current = nil
    used = 0
    loop do
      word = words[index + used]
      ordinal = ordinal_value(word, current)
      return [total + current.to_i + ordinal, used + 1] if ordinal

      step = advance(word, total, current)
      break unless step

      total, current = step
      used += 1
    end
    used.zero? ? [0, 0] : [total + current.to_i, used]
  end

  def ordinal_value(word, current)
    return ORDINALS.fetch(word) if ORDINALS.key?(word) && (current.nil? || (current % 10).zero?)

    TENS_ORDINALS.fetch(word) if TENS_ORDINALS.key?(word) && current.nil?
  end

  def advance(word, total, current)
    if UNITS.key?(word) && unit_fits?(current)
      [total, current.to_i + UNITS.fetch(word)]
    elsif TENS.key?(word) && tens_fit?(current)
      [total, current.to_i + TENS.fetch(word)]
    elsif SCALES.key?(word) && current
      scale(word, total, current)
    end
  end

  def unit_fits?(current)
    current.nil? || ((current % 100) >= 20 && (current % 10).zero?) || (current % 100).zero?
  end

  def tens_fit?(current) = current.nil? || ((current % 100).zero? && current.positive?)

  def scale(word, total, current)
    SCALES.fetch(word) == 1000 ? [total + (current * 1000), nil] : [total, current * 100]
  end
end

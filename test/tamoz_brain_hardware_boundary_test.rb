# frozen_string_literal: true

require_relative 'test_helper'

# An eval for the physical loop's deepest invariant, ADR-038: tamoz is the BRAIN.
# It proposes typed, abstract intent (a mode — `request_bounded_cooling`); it must
# never know about the hardware that carries the intent out. "Do not give Tamoz
# the serial port." The deterministic dispatch — and every device mechanism — is
# the Go authority's, deliberately outside tamoz.
#
# This is what lets the physical eval be independent and hardware-free: if the
# brain never names a serial port, a GPIO pin, a firmware, or an actuator, then
# no hardware is needed to evaluate it, and a bench run tests the DISPATCHER, not
# the brain. So the property is checkable offline, over tamoz's own source: no
# hardware-mechanism token appears anywhere in production code.
#
# Today this passes — tamoz's brain is provably hardware-free. It is a GUARANTEE,
# not a pending gap: it fails loudly the moment a device mechanism leaks into
# tamoz, which is exactly when the "brain knows no hardware" contract would break.
class TamozBrainHardwareBoundaryTest < Minitest::Test
  # Unambiguous hardware-mechanism tokens: physical I/O, board/firmware, and
  # actuation hardware. Deliberately NOT generic words a brain uses abstractly
  # (intent, dispatch policy, physical situation, effect) — only the mechanism a
  # judgment layer has no business naming.
  #
  # Word tokens use letter-boundary lookarounds, NOT \b: `_` is a regex word
  # character, so \b would miss the idiomatic snake_case leak (`gpio_pin`,
  # `i2c_bus`, `baud_rate`) — exactly how hardware appears in Ruby. `(?<![a-z])…
  # (?![a-z])` still rejects benign letter runs (`spin`, `crispier`, `servomotor`)
  # while catching a token adjacent to `_`, a digit, or punctuation.
  WORD_TOKENS = %w[
    gpio i2c spi pwm firmware arduino esp32 raspberry modbus rs232 rs485 baud
    solenoid servo actuator relay_pin
  ].freeze
  HARDWARE_PATTERNS = [
    /(?<![a-z])(?:#{WORD_TOKENS.join('|')})(?![a-z])/i,
    /serial[ _]?port/i,
    %r{/dev/tty}i
  ].freeze

  # Known-benign exceptions, each justified. Empty today: the brain names no
  # hardware at all. A future benign use is documented here rather than by
  # widening the token set.
  ALLOWLIST = [].freeze

  # The brain is the judgment worker's production code: the gem libraries plus the
  # bin launchers that COMPOSE them (the wiring point where a serial port would
  # plausibly be injected). `script/` (tooling), `agenteval/` (the eval harness),
  # and test trees are not the brain.
  def production_ruby_files
    gem_libs = Dir.glob(File.join(ROOT, 'gems', '*', 'lib', '**', '*.rb'))
    launchers = Dir.glob(File.join(ROOT, 'bin', '*')).select { |path| File.file?(path) }
    (gem_libs + launchers).reject { |path| path.end_with?('_test.rb') }
  end

  def test_the_brain_names_no_hardware_mechanism
    files = production_ruby_files
    refute_empty files, 'expected to scan tamoz production Ruby'

    violations = files.flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        next unless HARDWARE_PATTERNS.any? { |pattern| pattern.match?(line) }

        location = "#{relative}:#{index + 1}"
        next if ALLOWLIST.include?(location)

        "#{location}  #{line.strip}"
      end
    end

    assert_empty violations,
                 "tamoz is the brain and must not know about hardware (ADR-038: do not give Tamoz the " \
                 "serial port). A hardware-mechanism token leaked into production code:\n#{violations.join("\n")}"
  end
end

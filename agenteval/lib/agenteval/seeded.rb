# frozen_string_literal: true

module Agenteval
  # Deterministic naming and value generation. Every scenario is a pure function of its
  # seed, so a task is reproducible byte-for-byte while never being the same bytes twice
  # across seeds. This is what keeps the corpus out of training data and out of reach of
  # anyone tuning to it.
  class Seeded
    ADJECTIVES = %w[
      brisk calm dense eager fair glossy humid ionic jagged keen lucid mellow nimble
      opaque plush quiet rustic supple tidy upbeat vivid warm zesty amber bronze
    ].freeze

    NOUNS = %w[
      meadow harbor lantern quarry beacon thicket cinder marble willow canyon ember
      trellis pebble glacier orchard summit hollow prairie basin ridge delta cove
    ].freeze

    VERBS = %w[
      scale offset clamp fold shift blend trim widen damp boost skew normalize
    ].freeze

    UNITS = %w[
      two three four five six seven eight nine ten eleven twelve
    ].freeze

    def initialize(seed)
      @seed = seed
      @random = Random.new(seed)
      @taken = {}
    end

    attr_reader :seed

    def pick(list) = list[@random.rand(list.length)]

    def int(range) = @random.rand(range)

    # A stable, unique, pronounceable identifier — the kind of name a human would write,
    # so the generated project reads like code rather than like a fuzzer's output.
    def identifier(kind = :symbol)
      loop do
        name =
          case kind
          when :package then "#{pick(ADJECTIVES)}_#{pick(NOUNS)}"
          when :function then "#{pick(VERBS)}_by_#{pick(UNITS)}"
          else "#{pick(ADJECTIVES)}_#{pick(NOUNS)}"
          end
        next if @taken.key?(name)

        @taken[name] = true
        return name
      end
    end

    def shuffle(list) = list.shuffle(random: @random)

    def sample(list, count) = shuffle(list).first(count)
  end
end

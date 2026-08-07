# frozen_string_literal: true

require 'psych'

module Tamoz
  module Agent
    class Profile
      # The pre-parse YAML safety scan (P8-E). It walks the event stream BEFORE
      # anything is loaded and refuses the constructs that would let a profile
      # mean something other than what an operator reading it would conclude:
      # foreign tags, more than one document, merge keys, duplicate keys, aliases
      # in key position, complex (collection) keys, unbounded aliases, and
      # unbounded nesting.
      #
      # This is a Psych::Handler subclass rather than the anonymous class over
      # closures it replaces: the scan is inherently stateful — a frame stack, an
      # alias count, a document count — and holding that state in ivars lets each
      # refusal be a named method instead of a lambda captured by `define_method`.
      #
      # Pinned by test/agent_profile_schema_seams_test.rb (merge keys, nesting)
      # and test/agent_profile_test.rb (tags, aliases, duplicate keys, multiple
      # documents, alias-in-key-position, complex keys).
      # :reek:FeatureEnvy — the scanner's whole job is to drive the frame stack;
      # the coordination lives here and the per-frame questions live on Frame.
      # :reek:LongParameterList :reek:DataClump — `scalar`, `start_mapping` and
      # `start_sequence` are Psych::Handler's callback signatures, and the
      # (tag, anchor, style) trio is what the parser hands every one of them. The
      # parser chooses the shape; this class only implements it.
      # :reek:TooManyMethods — eight are Psych callbacks this class must answer to
      # and four are Frame's own accessors; what is left is one refusal each.
      # :reek:MissingSafeMethod — every bang here is a refusal that raises. There
      # is deliberately no predicate twin: a scanner you can ask without being
      # stopped is a scanner someone will forget to act on.
      # :reek:UncommunicativeVariableName — rubocop's
      # Naming/RescuedExceptionsVariableName requires `e`; the toolchain wins over
      # reek's preference (CODING_STANDARD §1).
      class YamlScanner < Psych::Handler
        # One frame per open collection. `expecting_key` alternates on every slot,
        # which is how key position is known without re-parsing; only mappings
        # track the keys they have already seen.
        Frame = Struct.new(:mapping, :seen_keys, :expecting_key) do
          def self.mapping = new(true, [], true)
          def self.sequence = new(false, nil, false)

          def key_slot? = mapping && expecting_key
          def advance! = self.expecting_key = !expecting_key
          def seen?(key) = seen_keys.include?(key)
          def record!(key) = seen_keys << key
        end

        def self.call(text, path)
          Psych::Parser.new(new(path)).parse(text)
        rescue Psych::SyntaxError => e
          raise ValidationError, "#{path}: invalid YAML: #{e.message}"
        end

        def initialize(path)
          @path = path
          @aliases = 0
          @documents = 0
          @stack = []
          super()
        end

        # rubocop:disable Metrics/ParameterLists -- Psych::Handler's signature
        def scalar(value, _anchor, tag, _plain, _quoted, _style)
          check_tag!(tag)
          note_slot!(value)
        end
        # rubocop:enable Metrics/ParameterLists

        def start_document(_version, _tags, _implicit)
          @documents += 1
          return if @documents == 1

          raise ValidationError,
                "#{@path}: a profile is exactly one YAML document; trailing documents " \
                'are silently ignored by the loader and are therefore refused'
        end

        # P8-E: an alias in *key* position resolves to whatever the anchor holds,
        # so the duplicate-key and merge-key scans never see the real key.
        # `policy: {allow_changes: false, *k: true}` with `&k "allow_changes"`
        # reads as a denial but loads as a grant. A key is a literal scalar.
        def alias(_anchor)
          @aliases += 1
          raise ValidationError, "#{@path}: too many YAML aliases (limit #{MAX_ALIASES})" if @aliases > MAX_ALIASES
          raise ValidationError, "#{@path}: YAML aliases are not allowed in mapping key position" if key_position?

          note_slot!(nil)
        end

        def start_mapping(_anchor, tag, _implicit, _style)
          check_tag!(tag)
          reject_complex_key!
          note_slot!(nil)
          push!(Frame.mapping)
        end

        def end_mapping
          @stack.pop
        end

        def start_sequence(_anchor, tag, _implicit, _style)
          check_tag!(tag)
          reject_complex_key!
          note_slot!(nil)
          push!(Frame.sequence)
        end

        def end_sequence
          @stack.pop
        end

        private

        def frame
          @stack.last
        end

        def key_position?
          frame&.key_slot? || false
        end

        def check_tag!(tag)
          return unless tag && !tag.start_with?('tag:yaml.org,2002:')

          raise ValidationError, "#{@path}: YAML tags are not allowed in profiles"
        end

        # A collection opened in key position is a YAML complex key. Nothing in the
        # schema has one, and it defeats the literal-key duplicate scan, so it is a
        # typed rejection rather than something the key allowlist happens to catch.
        def reject_complex_key!
          return unless key_position?

          raise ValidationError, "#{@path}: YAML complex (collection) keys are not allowed"
        end

        # Advances the mapping's key/value alternation, refusing anything that
        # would smuggle a key past the duplicate scan.
        def note_slot!(key)
          current = frame
          return unless current&.mapping

          refuse_unsafe_key!(current, key) if current.expecting_key
          current.advance!
        end

        # YAML merge keys splice one mapping into another after parsing, which
        # would let an anchor introduce keys the duplicate scan never saw.
        def refuse_unsafe_key!(current, key)
          raise ValidationError, "#{@path}: YAML merge keys are not allowed in profiles" if key == '<<'
          raise ValidationError, "#{@path}: duplicate key #{key.inspect}" if key && current.seen?(key)

          current.record!(key) if key
        end

        def push!(new_frame)
          raise ValidationError, "#{@path}: YAML nesting exceeds #{MAX_NESTING}" if @stack.length >= MAX_NESTING

          @stack << new_frame
        end
      end
    end
  end
end

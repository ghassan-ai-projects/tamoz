# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # The observation ledger: what the model has been shown, per path. A record holds the file
    # version the model saw and the scrubbed bytes it saw, retained so a later outside change can
    # be diffed against them. `ref` is nil when the file moved inside the read itself, which makes
    # the next edit to it fail stale_file — the right outcome.
    class WorkObservations
      READ_HEADER = /\AFile: (?<path>.+)\nsha256: (?<sha>[0-9a-f]{64})\n/
      READ_RANGE = /^lines: (?<first>\d+)-(?<last>\d+) of (?<total>\d+)/

      def initialize(ledger, root:, store:, scrub:)
        @ledger = ledger || {}
        @root = root
        @store = store
        @scrub = scrub
        freeze
      end

      def [](path) = @ledger[path]
      def to_h = @ledger

      # F3/F4: an apply_patch may only touch a path the model has been shown, at the version it
      # was shown. The refusal is a value, not an exception, and writes nothing either way.
      def refusal(name, arguments)
        return nil unless name == 'apply_patch'

        path = arguments.fetch('path')
        observed = @ledger[path]
        return not_observed(path) unless observed&.fetch('read')
        return nil if observed.fetch('sha256') == disk_digest(path)

        Core::ToolCodes.render(Core::ToolCodes::STALE_FILE,
                               "#{path} changed since you last read it; re-read the part you need.")
      end

      def pinned_digest(path) = @ledger.fetch(path).fetch('sha256')

      # The ledger is read by the gate and by nothing else, so this stays public.
      def not_observed(path)
        Core::ToolCodes.render(Core::ToolCodes::NOT_OBSERVED,
                               "read #{path} first (a range around the edit is enough), then retry.")
      end

      # A read result carries the whole-file sha in its header, whole or ranged.
      def record_read(output, step:)
        match = READ_HEADER.match(output)
        return self unless match

        move(match[:path], match[:sha], step:, range: read_range(output), read: true)
      end

      # A created file is not an observed one. `create_file` refuses to overwrite, so the model
      # cannot have been shown bytes it brought into existence in the same breath — and without
      # this, one create_file plus an apply_patch is a blind edit with extra steps. The version is
      # still recorded (a later outside change reads `stale_file`), but `read: false` keeps the
      # path unpatchable until a read reports it.
      def record_create(path, step:) = move(path, disk_digest(path), step:, range: nil, read: false)

      def record_write(path, step:)
        digest = disk_digest(path)
        return self if digest == 'absent'

        move(path, digest, step:, range: nil, read: true)
      end

      private

      def disk_digest(path)
        Tamoz::Tools::Toolbox.observe(@root.join(path)).fetch('state')
      end

      def move(path, sha, step:, range:, read:)
        record = { 'sha256' => sha, 'ref' => retain(path, sha), 'step' => step, 'range' => range,
                   'read' => read }.freeze
        self.class.new(@ledger.merge(path => record), root: @root, store: @store, scrub: @scrub)
      end

      def retain(path, sha)
        absolute = @root.join(path)
        return nil unless absolute.file?

        bytes = absolute.read(encoding: Encoding::UTF_8)
        return nil unless Digest::SHA256.hexdigest(bytes) == sha

        ContextEngine::Surface.retain(@store, @scrub.call(bytes))
      rescue SystemCallError, IOError, EncodingError
        nil
      end

      def read_range(output)
        match = READ_RANGE.match(output)
        match ? [match[:first].to_i, match[:last].to_i] : nil
      end
    end
  end
end

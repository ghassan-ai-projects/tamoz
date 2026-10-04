# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'optionparser'

module Tamoz
  module Agent
    # `diagnose`, `explain` and `postmortem`: read-only questions about this runtime's own record.
    module CLISelfObservationCommands
      DURATION = /\A(\d+)([mhd])\z/
      UNIT_MS = { 'm' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000 }.freeze

      def cmd_diagnose(options, argv)
        window = { since: '24h' }
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz diagnose [--since DURATION] [--json]'
          accept_json(parser, options)
          parser.on('--since DURATION', 'Window, e.g. 30m, 24h, 7d (default 24h)') { |value| window[:since] = value }
        end.parse!(argv)
        now = now_ms
        report = self_observation(options).diagnose(now_ms: now, since_ms: now - duration_ms(window[:since]))
        @out.puts(options[:json] ? report.to_json : Tamoz::Observability::Diagnosis::Markdown.render(report.to_h))
        0
      end

      def cmd_explain(options, argv)
        request = nil
        parser = OptionParser.new do |entry|
          entry.banner = 'Usage: tamoz explain THREAD [--request ID] [--json]'
          accept_json(entry, options)
          entry.on('--request ID', 'Effects of this request; checkpoints show execution context') do |value|
            request = value
          end
        end
        parser.parse!(argv)
        thread = argv.shift or raise OptionParser::MissingArgument, 'THREAD'
        record = self_observation(options).explain(thread:, request:)
        @out.puts(options[:json] ? JSON.generate(record) : JSON.pretty_generate(record))
        0
      end

      def cmd_postmortem(options, argv)
        settings = postmortem_settings(argv, options)
        now = now_ms
        postmortem = self_observation(options).postmortem(
          title: settings.fetch(:title), now_ms: now, since_ms: now - duration_ms(settings.fetch(:since)),
          until_ms: now, analysis: settings[:analysis] && read_analysis(settings[:analysis])
        )
        write_postmortem(postmortem, settings.fetch(:out), options)
      end

      def cmd_self_observe(options, argv)
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz --runtime-dir DIR [--session-dir DIR] self-observe  (a stdio MCP server)'
          accept_json(parser, options)
        end.parse!(argv)
        runtime_dir = options[:runtime_dir] || @env['TAMOZ_RUNTIME_DIR']
        SelfObserveServer.new(runtime_dir:, session_dir: options[:session_dir]).serve
        0
      end

      private

      def postmortem_settings(argv, options)
        settings = { since: '24h' }
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz postmortem --title TEXT --out DIR [--since DURATION] [--analysis FILE] [--json]'
          accept_json(parser, options)
          parser.on('--title TEXT', 'What happened, in a few words') { |value| settings[:title] = value }
          parser.on('--out DIR', 'Directory the postmortem files are written to') { |value| settings[:out] = value }
          parser.on('--since DURATION', 'Window, e.g. 30m, 24h, 7d (default 24h)') { |value| settings[:since] = value }
          parser.on('--analysis FILE', 'A findings report from `tamoz investigate --json`') do |value|
            settings[:analysis] = value
          end
        end.parse!(argv)
        %i[title out].each { |key| raise OptionParser::MissingArgument, "--#{key}" unless settings[key] }
        settings
      end

      def write_postmortem(postmortem, directory, options)
        directory = File.expand_path(directory)
        FileUtils.mkdir_p(directory, mode: 0o700) unless File.directory?(directory)
        stem = File.join(directory, "postmortem-#{postmortem.fetch('generated_at_ms')}")
        Tamoz::Core::AtomicFile.replace("#{stem}.json", JSON.pretty_generate(postmortem), mode: 0o600)
        Tamoz::Core::AtomicFile.replace("#{stem}.md", Tamoz::Observability::Postmortem.to_markdown(postmortem),
                                        mode: 0o600)
        @out.puts(options[:json] ? JSON.generate('json' => "#{stem}.json", 'markdown' => "#{stem}.md") : "#{stem}.md")
        0
      rescue SystemCallError => e
        raise SelfObservation::Error, "--out #{directory}: #{e.message}"
      end

      def read_analysis(path)
        JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      rescue JSON::ParserError, SystemCallError => e
        raise OptionParser::InvalidArgument, "--analysis #{path}: #{e.message}"
      end

      def self_observation(options)
        runtime_dir = options[:runtime_dir] || @env['TAMOZ_RUNTIME_DIR']
        session_dir = options[:session_dir] || (@sessions.resolve_session_dir(options) unless runtime_dir)
        SelfObservation.open(runtime_dir:, session_dir:)
      end

      def duration_ms(text)
        match = DURATION.match(text.to_s) or raise OptionParser::InvalidArgument,
                                                   "duration #{text.inspect} (use 30m, 24h, 7d)"
        Integer(match[1]) * UNIT_MS.fetch(match[2])
      end

      def now_ms = (Time.now.to_f * 1000).to_i
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    # Reads a runtime's durable record and journal once, read-only, and answers diagnosis questions about it.
    class SelfObservation
      # An operator error whose message cannot expose secret-shaped metadata.
      class Error < Tamoz::Agent::Error
        def initialize(message = nil) = super(message && Tamoz::Core.scrub_secrets(message))
      end

      Database = Data.define(:name, :path, :approval_link)

      THREAD_KINDS = %i[requests effects effect_attempts checkpoints].freeze

      def self.open(runtime_dir: nil, session_dir: nil, limit: nil)
        require 'tamoz/sqlite'
        databases = runtime_database(runtime_dir) + session_databases(session_dir)
        raise Error, 'no Tamoz database found; pass --runtime-dir or --session-dir' if databases.empty?

        new(databases:, journal_directory: runtime_dir && File.expand_path(runtime_dir),
            limit: limit || Tamoz::SQLite::RecordReader::DEFAULT_LIMIT)
      end

      def self.runtime_database(directory)
        return [] unless directory

        path = File.join(File.expand_path(directory), RuntimeDirectory::DATABASE_FILE)
        if File.file?(path)
          [Database.new(name: RuntimeDirectory::DATABASE_FILE, path:,
                        approval_link: :time_window)]
        else
          []
        end
      end

      def self.session_databases(directory)
        return [] unless directory

        Dir.glob(File.join(File.expand_path(directory), '*.sqlite3')).map do |path|
          Database.new(name: File.basename(path), path:, approval_link: :database)
        end
      end
      private_class_method :runtime_database, :session_databases

      attr_reader :databases

      def initialize(databases:, journal_directory:, limit:)
        @databases = databases
        @limit = limit
        @journal = journal(journal_directory)
      end

      def diagnose(now_ms:, since_ms:, rules: Tamoz::Observability::Diagnosis::Rules.default)
        Tamoz::Observability::Diagnosis.run(sources:, journal: @journal, now_ms:, since_ms:, rules:)
      end

      def explain(thread:, request: nil)
        database, records = @databases.lazy.map { |entry| [entry, thread_records(entry, thread)] }
                                           .find { |_entry, rows| rows.fetch('requests').any? }
        raise Error, "no durable request for thread #{thread}" unless database

        Tamoz::Observability::Explanation.build(records, thread:, request:, approval_link: database.approval_link,
                                                         now_ms: (Time.now.to_f * 1000).to_i)
                                         .merge('database' => Tamoz::Core.scrub_secrets(database.name),
                                                'truncated' => records.select do |_kind, rows|
                                                  rows.length >= @limit
                                                end.keys.sort)
      rescue Tamoz::Observability::ValidationError => e
        raise Error, e.message
      end

      def timeline(since_ms:, until_ms:, rules: Tamoz::Observability::Diagnosis::Rules.default)
        Tamoz::Observability::Timeline.build(
          Tamoz::Observability::Diagnosis.merge(sources), journal_documents: @journal.fetch(:documents),
                                                          journal_names: journal_names(rules), since_ms:, until_ms:
        )
      end

      def postmortem(title:, now_ms:, since_ms:, until_ms:, analysis: nil)
        report = diagnose(now_ms:, since_ms:).to_h
        Tamoz::Observability::Postmortem.build(title:, report:, until_ms:, analysis:,
                                               timeline: timeline(since_ms:, until_ms:))
      rescue Tamoz::Observability::ValidationError => e
        raise Error, e.message
      end

      private

      def sources
        @sources ||= @databases.map do |database|
          Tamoz::Observability::Diagnosis::Source.new(name: database.name, records: all_records(database),
                                                      limit: @limit)
        end
      end

      def all_records(database)
        read(database) do |reader|
          Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, reader.public_send(kind, limit: @limit)] }
        end
      end

      def thread_records(database, thread)
        read(database) do |reader|
          THREAD_KINDS.to_h { |kind| [kind.to_s, reader.public_send(kind, thread:, limit: @limit)] }
                      .merge('approval_decisions' => reader.approval_decisions(limit: @limit))
        end
      end

      def read(database)
        reader = Tamoz::SQLite::RecordReader.open(path: database.path)
        yield reader
      rescue Tamoz::SQLite::Error, Tamoz::ConfigurationError, SQLite3::Exception => e
        raise Error, "#{database.name}: #{e.message}"
      ensure
        reader&.close
      end

      def journal(directory)
        return { documents: [], drops: {} } unless directory && File.directory?(directory)

        journal_class = Tamoz::Observability::Recorder::Journal
        { documents: journal_class.read(directory), drops: journal_class.drop_counts(directory) }
      rescue SystemCallError => e
        raise Error, "the telemetry journal in #{directory} cannot be read: #{e.class.name}"
      end

      def journal_names(rules)
        rules.rules.select { |rule| rule.detector == 'journal_events' }.flat_map { |rule| rule.fetch('names') }
      end
    end
  end
end

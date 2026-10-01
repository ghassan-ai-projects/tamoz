# frozen_string_literal: true

require 'psych'

module Tamoz
  module Agent
    class Profile
      # Operator adoption registry (§3.6): which profile digests the operator has
      # explicitly activated. Lives outside profile files and any repository,
      # mode 0600, and never participates in any canonical digest.
      #
      # This class owns STORAGE — where the file is, that it stays owner-only, and
      # how an activation is appended. Whether the bytes it reads may be believed
      # is AdoptionDocument's question.
      #
      # :reek:DataClump — activated?, activate and append each act on one (profile_id, digest) pair.
      class AdoptionRegistry
        REGISTRY_SCHEMA_VERSION = AdoptionDocument::SCHEMA_VERSION

        attr_reader :path

        # :reek:ControlParameter — `path:` is the injection seam the tests use;
        # production passes nil and takes the operator's configured location.
        def initialize(path: nil, env: ENV)
          @path = path || Profile.adoption_path(env:)
          freeze
        end

        def activated?(profile_id, digest)
          digests(profile_id).include?(digest)
        end

        def digests(profile_id)
          document.fetch('activated').fetch(profile_id, [])
        end

        # `document` verifies permissions and yields the empty document when no
        # registry exists yet, so a registry someone else can read raises here
        # before anything is written. The read-modify-write holds the registry's
        # lock file, so two processes activating at once cannot lose one digest.
        def activate(profile_id, digest)
          Tamoz::Core::PrivateDirectory.secure(File.dirname(@path))
          Tamoz::Core::FileLock.exclusive("#{@path}.lock") { append(profile_id, digest) }
        end

        private

        def append(profile_id, digest)
          current = document
          activated = current.fetch('activated')
          list = activated.fetch(profile_id, [])
          return if list.include?(digest)

          write(current.merge('activated' => activated.merge(profile_id => list + [digest])))
        end

        def write(updated)
          Tamoz::Core::AtomicFile.replace(@path, Psych.dump(updated), mode: 0o600)
        end

        # :reek:TooManyStatements — read, verify, parse, validate, normalize is
        # the whole of the read path and is not meaningfully divisible.
        # :reek:UncommunicativeVariableName — rubocop's
        # Naming/RescuedExceptionsVariableName requires `e`; the toolchain wins
        # over reek's preference here (CODING_STANDARD §1).
        def document
          return AdoptionDocument.empty unless File.exist?(@path)

          Profile.verify_permissions!(@path)
          data = Psych.safe_load(
            File.binread(@path), permitted_classes: [], permitted_symbols: [], aliases: false
          )
          raise AdoptionError, "#{@path}: adoption registry is invalid" unless AdoptionDocument.new(data).valid?

          Profile.normalize_keys(data)
        rescue Psych::Exception => e
          raise AdoptionError, "#{@path}: adoption registry is unreadable: #{e.message}"
        end
      end
    end
  end
end

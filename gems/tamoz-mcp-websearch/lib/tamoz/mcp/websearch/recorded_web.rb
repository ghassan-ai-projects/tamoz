# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module Tamoz
  module Mcp
    module Websearch
      # A hard cap on paid searches, shared by every process that names the same counter file
      # ({"cap": 500, "used": 0}).
      class SearchLedger
        # Raised by charge! when the counter file's used has reached its cap: the search is refused, not charged.
        class Exhausted < StandardError; end

        def initialize(path)
          @path = path
        end

        def charge!
          File.open(@path, File::RDWR) do |file|
            file.flock(File::LOCK_EX)
            ledger = JSON.parse(file.read)
            raise Exhausted, "the search budget of #{ledger.fetch('cap')} requests is spent" if
              ledger.fetch('used') >= ledger.fetch('cap')

            ledger['used'] += 1
            file.rewind
            file.write(JSON.generate(ledger))
            file.truncate(file.pos)
          end
        end
      end

      # Searches by normalised query and pages by URL, kept in a directory: a repeat costs no request, and runs that
      # share the directory see the same web. A live search is charged to the ledger first.
      class RecordedWeb
        def initialize(dir:, ledger: nil)
          @dir = dir
          @ledger = ledger
          FileUtils.mkdir_p(dir) if dir
        end

        def search(query, count)
          recorded("search-#{digest("#{query.downcase.split.join(' ')}\n#{count}")}") do
            @ledger&.charge!
            yield
          end
        end

        def read(url, &) = recorded("page-#{digest(url)}", &)

        private

        def digest(text) = Digest::SHA256.hexdigest(text)[0, 32]

        def recorded(key)
          return yield unless @dir

          path = File.join(@dir, "#{key}.json")
          return JSON.parse(File.read(path)) if File.exist?(path)

          value = yield
          File.write("#{path}.partial", JSON.generate(value))
          File.rename("#{path}.partial", path)
          value
        end
      end
    end
  end
end

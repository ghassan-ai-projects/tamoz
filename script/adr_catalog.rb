# frozen_string_literal: true

# Generates documentation/adr/catalog.json from the ADR files, the only source of truth.
#
#   ruby script/adr_catalog.rb [dir]            # write catalog.json
#   ruby script/adr_catalog.rb --check [dir]    # exit 1 when catalog.json is stale

require 'json'

# Parses ADR files into catalog records; `json` is the catalog's exact bytes.
module AdrCatalog
  DEFAULT_DIR = File.expand_path('../documentation/adr', __dir__)
  HEADER = /^\*\*(?<key>[A-Za-z ]+):\*\*\s*(?<value>.+)$/

  module_function

  def headers(text)
    text.each_line.with_object({}) do |line, found|
      match = HEADER.match(line)
      found[match[:key]] ||= match[:value].strip if match
    end
  end

  def numbers(value) = value.to_s.scan(/ADR-(\d{3})/).flatten.uniq.sort

  def state(status)
    case status
    when /\ARetired\b/ then 'retired'
    when /\AProposed\b/ then 'proposed'
    else 'accepted'
    end
  end

  def parse(path)
    text = File.read(path, encoding: Encoding::UTF_8)
    fields = headers(text)
    status = fields.fetch('Status', '')
    {
      'num' => File.basename(path)[/\Aadr-(\d{3})-/, 1],
      'title' => text[/^#\s+ADR-\d{3}\s+—\s+(.+?)(?:\s+\(RETIRED\))?$/, 1].to_s.strip,
      'status' => status,
      'state' => state(status),
      'date' => fields['Date'].to_s[/\d{4}-\d{2}-\d{2}/],
      'tier' => fields['Tier'],
      'implementation' => fields['Implementation'],
      'file' => File.basename(path),
      **relations(fields, status),
      'sections' => text.scan(/^##\s+(.+)$/).flatten.map(&:strip)
    }
  end

  def relations(fields, status)
    {
      'relates_to' => numbers(fields['Relates to']),
      'supersedes' => numbers(fields['Supersedes']),
      'superseded_by' => status.start_with?('Retired') ? numbers(status) : [],
      'amends' => numbers(fields['Amends']),
      'amended_by' => numbers(fields['Amended by'])
    }
  end

  def build(dir = DEFAULT_DIR)
    adrs = Dir[File.join(dir, 'adr-*.md')].map { |path| parse(path) }.sort_by { |adr| adr['num'] }
    {
      'generated_by' => 'script/adr_catalog.rb',
      'count' => adrs.size,
      'next_number' => (adrs.map { |adr| adr['num'].to_i }.max || 0) + 1,
      'states' => adrs.group_by { |adr| adr['state'] }.transform_values(&:size).sort.to_h,
      'adrs' => adrs
    }
  end

  def json(dir = DEFAULT_DIR) = "#{JSON.pretty_generate(build(dir))}\n"

  def path(dir = DEFAULT_DIR) = File.join(dir, 'catalog.json')

  def current?(dir = DEFAULT_DIR)
    File.exist?(path(dir)) && File.read(path(dir), encoding: Encoding::UTF_8) == json(dir)
  end
end

if $PROGRAM_NAME == __FILE__
  check = ARGV.delete('--check')
  dir = ARGV.first || AdrCatalog::DEFAULT_DIR
  if check
    abort 'catalog.json is STALE — run: ruby script/adr_catalog.rb' unless AdrCatalog.current?(dir)
    puts "catalog.json is up to date (#{AdrCatalog.build(dir)['count']} ADRs)"
  else
    File.write(AdrCatalog.path(dir), AdrCatalog.json(dir))
    puts "wrote #{AdrCatalog.path(dir)} (#{AdrCatalog.build(dir)['count']} ADRs)"
  end
end

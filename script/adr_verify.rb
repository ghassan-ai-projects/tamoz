# frozen_string_literal: true

# Executable check of every ADR's `## Verification` evidence. For each backticked citation:
#   - a repo path (gems/…, documentation/…, docs/…, script/…, .github/…) must exist
#   - a `tamoz-*` gem name must have a gems/<name> directory
# unless the surrounding text asserts ABSENCE (absent/removed/deferred/retired/gone/zero),
# in which case the opposite is checked. Symbols, bare filenames, and globs are skipped.
# This turns "Verified against code" from prose into an alarm that fires when the code moves.
#
#   ruby script/adr_verify.rb        # exit 0 if every citation holds, else 1
#
# Wired as `rake adr:verify`.

ROOT = File.expand_path("..", __dir__)
ADR_DIR = File.join(ROOT, "documentation", "adr")
# Strong, unambiguous absence phrases only — plain words like "never"/"deferred"/"retired"
# appear in normal present-tense prose (e.g. "never actuates", "the retired ADR-012").
ABSENCE = /\babsent\b|does not exist|returns? zero|zero matches|no longer exists|was removed|correctly deferred/i
PATH_RE = %r{\A(?:gems|documentation|docs|script|\.github)/[\w./-]+\z}
GEM_RE  = /\Atamoz-[a-z0-9]+(?:-[a-z0-9]+)*\z/

problems = []
checked = 0

Dir[File.join(ADR_DIR, "adr-*.md")].sort.each do |path|
  text = File.read(path, encoding: Encoding::UTF_8)
  base = File.basename(path)
  ver = text[/^\#\#\s+(?:\d+\.\s+)?Verification\s*\n+(.+?)(?:\n\#\#\s|\z)/m, 1]
  next unless ver

  ver.to_enum(:scan, /`([^`]+)`/).each do
    tok = Regexp.last_match(1).strip
    next if tok.include?("*")
    at = ver.index("`#{tok}`") || 0
    absent_ctx = ver[[0, at - 60].max...(at + tok.length + 60)] =~ ABSENCE

    target =
      if tok =~ PATH_RE then File.join(ROOT, tok)
      elsif tok =~ GEM_RE then File.join(ROOT, "gems", tok)
      else next
      end

    checked += 1
    exists = File.exist?(target)
    if absent_ctx && exists
      problems << "#{base}: Verification says `#{tok}` is absent, but it exists"
    elsif !absent_ctx && !exists
      problems << "#{base}: Verification cites `#{tok}`, which does not exist"
    end
  end
end

if problems.empty?
  puts "adr:verify passed — #{checked} evidence citations all hold"
else
  warn "ADR verification FAILED (#{problems.size}):"
  problems.each { |p| warn "  - #{p}" }
  exit 1
end

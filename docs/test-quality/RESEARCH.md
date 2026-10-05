# Test library research

Checked 2026-10-04 against the installed bundle and upstream documentation.

## Library and applicable patterns

`Gemfile.lock` and a bundled runtime check identify Minitest **6.0.6** on Ruby **3.3.11**.
The suite uses `Minitest::Test`, not RSpec or Rails. Upstream explains that Minitest uses
Ruby classes, methods, modules and inheritance directly. Keep those ordinary mechanisms
instead of adding a custom specification language.
Source: [Minitest README](https://github.com/minitest/minitest).

The library provides result-specific assertions with expected/actual diagnostics.
Use predicates, membership, emptiness, nil and typed exceptions directly. Standard
assertions help both the reader and automated linting recognize the protected contract.
Source: [Minitest 6.0.6 assertions](https://docs.seattlerb.org/minitest/Minitest/Assertions.html).
Local verification: installed `lib/minitest/assertions.rb` and `lib/minitest/test.rb`.

Mock/stub support was extracted into **minitest-mock**. The local bundle cannot require
`minitest/mock`; introducing `Object#stub` would break it. Prefer current injected
collaborators and plain Ruby fakes. If mocks are installed separately later, expectations
must be verified and must not be shared across threads; upstream explicitly warns that
Minitest mocks do not support multithreading.
Source: [minitest-mock README](https://github.com/minitest/minitest-mock).

SimpleCov must start before production code loads. Its branch mode supplements line
coverage because an executed conditional line can still have an untested decision.
Compare fresh resultsets and name commands when merging processes; stale output is not
current evidence. This repository already has `test/support/simplecov_setup.rb` and
`script/quality/coverage_totals.rb`, so extend those seams.
Source: [SimpleCov documentation](https://github.com/simplecov-ruby/simplecov).

## Repository conclusions

The first improvements should be runner completeness, unique test identity, scoped
resource helpers, removal of literal duplicated helpers and deterministic waits. Apply
Minitest-specific assertion linting across all roots. Do not add dependencies, collapse
all fixtures into one object, or remove a safety test because its name contains a phase.
Renaming alone improves readability but does not prove speed or coverage.

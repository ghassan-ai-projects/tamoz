# tamoz-stream clean-code refactor log

## Bar (per file)
- Every function name states its intent.
- Each function is short and does one thing.
- Each function stays at one abstraction level.
- Public, top-level functions read like a small DSL.
- Functions call helpers one level below, stepping down to small concrete operations.

## Files processed

### situation_request.rb
- Bar: `validate!` reads as a list of domain validations; `run` reads as a short sequence of episode phases; helpers remove duplication.
- Status: done
- Commit: 62d9071

### approval_relay.rb
- Bar: `submit_decision` reads as the PROTOCOL §5/§10 submission sequence;
  `deliver` reads as validate → render → deliver; `initialize` is a list of
  port contracts; `escalate` decomposes into normalize → pick → payload.
- Status: done
- Notes: see behavior-notes.md (comma-joined port error text; rejected
  require_field! simplification).

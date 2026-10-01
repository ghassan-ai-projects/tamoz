# tamoz-core

Shared values and dependency-light runtime protocols for Tamoz.

```ruby
require "tamoz/core"

context = Tamoz::Context.new(
  run_id: "run.1",
  execution_id: "execution.1",
  request_id: "request.1"
)

state = Tamoz::StateCodec.new.normalize(
  "status" => "planned",
  "steps" => [{"id" => "inspect"}]
)

context.child("inspect").check!
```

Bounded execution (`Tamoz::Pool`, `Tamoz::StreamSink`) and the thread substrate
(`Tamoz::CancellationToken` and friends) now live in the `tamoz-concurrency`
and `tamoz-cancellation` gems; core keeps the values, protocols, and errors
they build on.

M1 includes explicit Context propagation, cooperative cancellation and monotonic deadlines,
versioned allowlisted state encoding, bounded execution streaming, safe instrumentation,
and ordered inline/thread execution. It contains no graph, persistence, provider, network,
or model behavior.

## File writes

Other gems write files only through three facades here: `Tamoz::Core::AtomicFile` (`replace` and
`create`: a write a reader sees whole or not at all, with the mode set before it is published),
`Tamoz::Core::PrivateDirectory.secure` (an owner-only directory, created or pre-existing) and
`Tamoz::Core::FileLock.exclusive` (an advisory lock on a dedicated lock file).
`test/file_facades_boundary_test.rb` names the few sanctioned exceptions.

# Phase 4 implementation bar: `tamoz-comms-gateway`

This bar is planned after `tamoz-evals-runner`; it is not authorization to
start before the preceding phase is committed and green.

- [ ] `tamoz-comms-gateway` owns the long-running `Gateway` and
      `DeliveryDrainer` process boundary, while `tamoz-comms` retains the
      channel-neutral values, errors, transport seam, store contract, and
      rendering/admission vocabulary.
- [ ] The new gem contains no fixture source, fixture data, fake transport,
      test server, or fixture-only dependency. Tests inject transports and
      stores explicitly from outside the package.
- [ ] The boundary has no direct Telegram dependency. Generic Comms error
      classification replaces the current
      `Tamoz::Telegram::ResponseTooLargeError` rescue before extraction.
- [ ] Lease fencing, inbound offset ordering, durable disposition, delivery
      claims, pacing, effect binding, ambiguous-send handling, authentication
      stop, checkpoint controls, and graceful shutdown remain behaviorally
      identical.
- [ ] The gateway gem declares its real direct dependencies, loads without the
      Telegram adapter, and has an installed hermetic process test with an
      injected transport and store.
- [ ] Public constants, executable/process entrypoints, package inventories,
      API docs, requirements/dependency artifacts, and operational docs agree
      with the new owner. No compatibility alias preserves the old owner.
- [ ] Targeted tests, RuboCop, Enola, packaging checks, and five independent
      reviews pass; pre-existing transport or provider debt is listed rather
      than hidden.

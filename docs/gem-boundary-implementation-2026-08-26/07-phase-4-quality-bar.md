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
- [ ] The Telegram adapter maps an oversized response into the generic Comms
      contract: an oversized poll is transient and an oversized send is
      ambiguous. The gateway rescues only channel-neutral Comms errors.
- [ ] The parent package no longer eagerly requires either process class;
      loading `tamoz-comms` alone does not define `Gateway` or
      `DeliveryDrainer`. The CLI, public API registry, and installed package
      metadata require and attribute the new gem explicitly. No compatibility
      alias is added.
- [ ] Every protocol the moved classes already receive indirectly is named in
      the boundary: transport, store/lease/offset/disposition, checkpoint,
      request-inbox/profile adapter, and effect binding. The implementation
      either declares the real package dependency or documents the injected
      protocol; it does not invent a second store or journal.
- [ ] Lease fencing, inbound offset ordering, durable disposition, delivery
      claims, pacing, effect binding, ambiguous-send handling, authentication
      stop, checkpoint controls, and graceful shutdown remain behaviorally
      identical.
- [ ] The extraction includes characterization evidence for the current
      offset-fence, pacing/claim, prompt-activation crash window, journal
      projection, and authentication-preflight behavior. Those existing
      behaviors are not silently redesigned as part of the package split; if a
      contract requires correction rather than characterization, it is recorded
      as a separate blocker and the phase cannot claim completion.
- [ ] The gateway gem declares its real direct dependencies, loads without the
      Telegram adapter, and has an installed hermetic process test with an
      injected transport and store.
- [ ] Public constants, executable/process entrypoints, package inventories,
      API docs, requirements/dependency artifacts, and operational docs agree
      with the new owner. No compatibility alias preserves the old owner.
- [ ] Targeted tests, RuboCop, Enola, packaging checks, and five independent
      reviews pass; pre-existing transport or provider debt is listed rather
      than hidden.

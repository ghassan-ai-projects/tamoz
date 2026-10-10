# tamoz-comms-gateway

The long-running communications process boundary for Tamoz. This gem owns
`Tamoz::Comms::Gateway` and `Tamoz::Comms::DeliveryDrainer` while consuming the
channel values, errors, transport seam, and `CommsStore` contract from
`tamoz-comms`.

The process receives its collaborators from the caller:

- a transport implementing `Tamoz::Comms::Transport`;
- an adapter that binds the existing `Tamoz::Comms::CommsStore` and its
  lease, offset, disposition, delivery, pacing, and journal operations;
- an optional `attachments:` handoff (`Tamoz::Core::AttachmentSpool`): a received
  file is written there for the worker, which deletes it once read — nothing is
  kept, and nothing goes into the database; without it, files are refused;
- checkpoint and request-inbox operations used for command controls;
- an optional request-inbox/profile controls adapter; and
- the existing durable effect binding carried by the CommsStore projection.

The package has no Telegram dependency, opens no channel by itself, and does
not contain fixtures, fake transports, test servers, or fixture data. Channel
adapters and test doubles are supplied by the application or repository test
support.

```ruby
require 'tamoz/comms/gateway'

gateway = Tamoz::Comms::Gateway.new(
  checkpoints: checkpoints,
  transport: transport,
  descriptor: descriptor,
  poller_owner: 'gateway:process'
)
```

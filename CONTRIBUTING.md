# Contributing to Airlock

Thank you for wanting to make Airlock better. Bug reports, ideas and pull
requests are all welcome.

## Before you start

- **Small, focused changes** are the easiest to accept. For anything bigger,
  open an issue first so we can agree on the shape before you spend the time.
- Run `swift build` and `swift test` before opening a pull request; both must
  pass.
- Match the code around you. This file is short on rules because the
  codebase states its own: an agent is one `AgentIntegration` conformer, a
  widget is one `NotchWidget` conformer, `SessionState.apply` is the only
  place session state changes, and hooks always fail open.
- Never paste code from another project unless its licence allows it and you
  say so in the pull request. Airlock is a clean-room implementation and
  contains no code from GPL-licensed notch apps; keep it that way.

## The contributor agreement

Airlock's source is published to read, but the app is sold. So that a
contribution can ship in the paid app, every contribution is made under this
agreement. Opening a pull request, or ticking the box in the pull request
template, means you agree to it.

**Airlock Individual Contributor License Agreement, version 1**

"You" means the person submitting a Contribution. "Contribution" means any
code, documentation or other material you submit to the Airlock repository
(<https://github.com/gdelolmo7/airlock>) for inclusion in Airlock. "Licensor"
means Guillermo del Olmo, and anyone he transfers Airlock to.

1. **Copyright licence.** You grant the Licensor a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable licence to reproduce,
   prepare derivative works of, publicly display, publicly perform,
   sublicense, and distribute your Contributions and such derivative works,
   under any terms the Licensor chooses, including in software that is sold
   and under licences other than the one Airlock's source is published under.
2. **Patent licence.** You grant the Licensor, and everyone who receives
   Airlock from the Licensor, a perpetual, worldwide, non-exclusive,
   no-charge, royalty-free, irrevocable patent licence to make, have made,
   use, sell, offer to sell, import and otherwise transfer your
   Contributions, for patent claims you can license that your Contribution,
   alone or combined with Airlock, would infringe.
3. **You keep your copyright.** This agreement is a licence, not a transfer.
   You can still use your own Contribution however you like.
4. **Your right to give it.** You confirm that each Contribution is your own
   original work, or that you have the right to submit it under this
   agreement, and that if your employer has rights in what you create, it has
   allowed this Contribution or waived those rights. If part of a
   Contribution is someone else's work, you say so in the pull request, with
   its source and licence.
5. **No obligation.** The Licensor does not have to use your Contribution.
6. **As is.** Unless required by law, you give your Contributions as is,
   without warranties of any kind, and you are not expected to support them.
7. **Telling us.** If you learn that any of the above is no longer true for a
   Contribution, you agree to tell the Licensor.

This agreement is based on the Apache Software Foundation's Individual
Contributor License Agreement, shortened and put in plain words.

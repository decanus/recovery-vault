# NOTES — judgement calls & deviations

Every place the build spec left a decision, and every place I wanted to deviate.

## Accounting model for `sweepUncredited` (I3 conservation)

The spec fixes I3 as `totalInflows == totalPayouts + totalSwept + poolBalance` but
does not state which state transitions touch which counter. The only assignment
that makes I3 a true invariant:

| Function | `poolBalance` | `totalInflows` | `totalPayouts` | `totalSwept` |
|---|---|---|---|---|
| `fund` | `+= amount` | `+= amount` | — | — |
| `creditUncredited` | `+= amount` | `+= amount` | — | — |
| `sweepUncredited` | — | `+= amount` | — | `+= amount` |
| `redeem` | `-= assets` | — | `+= assets` | — |

`sweepUncredited` **increments `totalInflows` as well as `totalSwept`**. Proof:
`RHS = payouts + swept + pool = redeems + sweeps + (funds + credits − redeems) =
funds + credits + sweeps = totalInflows`. If sweep touched only `totalSwept`, I3
would break the moment anything is swept. Semantically: `totalInflows` is "value
that entered the accounting system," whether it went to the pool or was recognised
and swept back out. A swept donation is counted at the moment of the sweep
decision, not at silent arrival. Documented in `RecoveryEscrow.sweepUncredited`.

## `fund` signature — dropped the `source` argument

§6 shows `escrow.fund(amount, REVENUE)`, but §4's "complete external surface" is
authoritative and lists `fund(uint256 amount)`, and §3 states attribution is
`msg.sender` on the `Funded` event, resolved off-chain. I implemented
`fund(uint256)` with a `Funded(from, amount)` event and made the spigot call
`escrow.fund(amount)`. The `REVENUE` enum from the design-space doc is not carried
into v1 — there is no on-chain provenance tag.

## `redeem` uses `claim.totalSupply()`, not a bare `totalSupply()`

§4.2's snippet writes `uint256 supply = totalSupply();`. The escrow has no
`totalSupply` of its own; the only correct reading is `claim.totalSupply()`
(matching §4.1 and the price table). Implemented as `claim.totalSupply()`.

## `redeem` when `supply == 0`

`amount == 0` is a permitted no-op *except* when `supply == 0`, where
`amount * poolBalance / supply` is `0/0` and reverts (EVM panic). This is only
reachable after every token has been burned, i.e. a terminal state where no one
holds anything to redeem. I left the spec's exact body (no guard) rather than add
a state variable / branch not in §4. The revert is harmless: it is a no-op call in
a dead state. The invariant handler guards this case so it does not pollute the
revert-rate metric.

## I1 monotonicity excludes the `supply == 0` terminal state

`pricePerClaim()` returns `0` when `supply == 0` (spec §4.1). The redemption that
drains the last tokens therefore takes the price from a positive value to `0`,
which is literally a *decrease*. I read I1 as "price non-decreasing **while there
are claims outstanding**": `invariant_I1` skips when `supply == 0`. Supply can
never recover post-finalisation, so this excludes exactly one terminal transition
and nothing else. Without this guard, I1 would false-positive on the very
last-holder-drains case the spec's own §8 rounding test exercises.

## I7 is a standalone enumerated test, not a per-call invariant

I7 ("no selector reduces the price") reads naturally as an *enumeration* of the
escrow's external surface, which a fuzz invariant does not express (and pre-
finalisation `distribute` legitimately lowers the price by growing supply, so a
blanket per-call assertion would be false). Implemented as
`test_I7_noSelectorReducesPrice`, which post-finalisation invokes every mutating
selector — `distribute`/`correct`/`finalize` (revert, price unchanged), `fund`,
`creditUncredited`, `sweepUncredited`, `redeem`, plus `claim.transfer` — and
asserts the price is non-decreasing for each. `invariant_I7_placeholder` keeps the
numbering contiguous in the invariant contract and points at the real test.

## Violation-flag pattern under `fail_on_revert = false`

With `fail_on_revert = false`, a failed `assert*` *inside a handler action* reverts
the handler call, and Foundry swallows it as "just another reverting call" — the
suite would pass while the property is violated. So I5, I6, I8, I9 are checked
inside the handler by **setting a ghost boolean** (never reverting) and asserted in
the corresponding `invariant_*` function via `assertFalse(flag)`. I1/I4
monotonicity use persisted previous-value trackers in the invariant contract.

## Handler is the escrow admin

The admin surface (`distribute`, `correct`, `finalize`, `creditUncredited`,
`sweepUncredited`) is `onlyAdmin`. For the handler to exercise it, the handler
**deploys the escrow in its own constructor**, making `admin == handler`. The
`Invariants` test reads `escrow`/`claim`/`asset` back off the handler.

## Cross-run state accumulation

Empirically (a throwaway probe, since removed) this Foundry version does **not**
reset handler state between invariant runs — `afterInvariant` observes ghosts
accumulated across the whole campaign. The coverage assertions
(`ghost_finalizedAt > 0`, `ghost_reachedZeroSupply`, `>40% holder fully exited`,
`preFinalizeRedeemAttempts > 0`) rely on this. If run under a Foundry that *does*
reset between runs, these would instead reflect only the final run; they would
still hold given the handler's biasing, but the guarantee weakens.

## `RevenueSpigot.route` semantics

The spec says "intercepts a fixed share". I implemented `route(source)` to pull
only `amount * shareBps / 10000` from the source (via `transferFrom`, so the
source must approve the spigot) and leave the remainder with the source, where
`amount = min(source balance, source allowance)`. A zero computed share reverts
(`NothingToRoute`) rather than emitting a no-op. `MIN_SHARE_BPS > 0` is enforced at
construction so the intercept can never be zeroed.

## Things I deliberately did **not** add

No merkle distribution, redemption floor, coupon/accrual, par state, surplus
sweep, lifecycle enum, pause, upgradeability, governance, multi-asset pool,
maturity/conversion. No storage variable beyond §4 on the escrow. The claim token
adds only `escrow` (immutable) and `mintingClosed` (the one-way latch, §5), which
§5 specifies.

## `mintingClosed` latch vs. per-mint escrow read

Per §5, the claim token holds its own `mintingClosed` latch flipped once by
`escrow.finalize() → claim.closeMinting()`, rather than reading `finalized` from
the escrow on every mint. This keeps the batch-distribution hot path free of a
cross-contract call.

# NOTES — design decisions

This system was originally specced with on-chain batched distribution and a
credited/uncredited ledger. It was then deliberately simplified. This file records
the decisions that shaped the current design.

## Distribution moved off-chain (merkle drop)

The full claim supply is minted once, at construction, to the creator. All on-chain
distribution machinery (`distribute`, `correct`, batched minting, `mint`,
`closeMinting`, the `mintingClosed` latch) was removed. The creator distributes the
tokens off-chain — the intended path is a merkle-drop distributor
([1inch/merkle-distribution](https://github.com/1inch/merkle-distribution)) whose
`claim` **transfers** pre-funded tokens rather than minting them, which is exactly
what a fixed-supply token needs.

Why this is safe: minting the whole supply up front means `claim.totalSupply()`
equals the full liability from birth, so redemption pricing is correct immediately
— no "supply smaller than liability, redeemer drains the pot" window. A lazy-minting
merkle drop would *not* be safe, because supply would grow as stragglers claim.

**Trust tradeoff (accepted):** direct on-chain distribution could misallocate but
never steal, because the admin never held redeemable claims. Minting 100% to the
creator inverts that — the creator transiently holds the entire supply. The
`finalize()` gate (redemption reverts until flipped) plus the discipline of
distributing before funding are the mitigations; the merkle root is publicly
auditable. This is appropriate for a recovery vehicle run by an accountable
administrator.

## The pot is `balanceOf`, not a ledger

The credited/uncredited ledger (`poolBalance`, `fund`, `creditUncredited`,
`sweepUncredited`, `uncredited`) was removed. `pricePerClaim`/`redeem` now read
`asset.balanceOf(address(this))` directly: **any asset at the escrow backs the
claims and is redeemable, regardless of provenance.**

This is a real product decision with a real consequence: a transfer in is
irreversible claimant money — there is no sweep to recover a mistaken or earmarked
transfer. It is safe against the classic attacks because supply is fixed (no
share-minting deposit, so no ERC-4626 inflation attack) and a donation only ever
raises the price pro-rata (a gift). Operationally, earmarked/uncleared funds must
simply be kept outside the escrow until they are unambiguously claimant property.

Because of this, invariant **I5 is inverted**: it was "a direct transfer does not
move the price"; it is now "funding never *lowers* the price." Solvency (I2) becomes
automatic — total claimable always equals the balance (minus floor dust).

## Removed on-chain running totals

`totalInflows`, `totalPayouts`, `totalSwept` were removed. They were pure telemetry
— never read by any logic. Every amount is already carried on an event
(`Redeemed`, and asset `Transfer` for inflows), so an indexer reconstructs any total
for free. Their only on-chain use was the conservation invariant I3, which is now
tracked via the invariant handler's ghost variables instead. This saves an SSTORE on
every redemption. `poolBalance -= assets` is *not* in this category — it was the
ledger and is gone with the ledger; the balance now decreases naturally on the
payout `transfer`.

## `finalize()` kept as the redemption gate

Its original job (close minting) is obsolete — supply is fixed at construction. Its
remaining job matters more: since the creator holds the whole supply at birth,
without a gate they could redeem the entire pot on day one. `finalize()` is one-way,
admin-only, and `redeem` reverts until it is called (invariant I6).

## `RevenueSpigot` funds by transfer

With no `fund` entrypoint, `route` transfers the intercepted share straight from the
source to the escrow address via `transferFrom`. The spigot never custodies funds
and never approves anything. Everything else (append-only `register`, permissionless
`route`, timelocked+clamped `shareBps`) is unchanged.

## `RecoveryPool` is auxiliary, not a change to the core

The LP extension adds two contracts and modifies none. `RecoveryEscrow`,
`RecoveryClaim` and `RevenueSpigot` are byte-for-byte unchanged and have no
knowledge of the pool — the integration is a transfer, which the balance-backed
escrow already accepts from anyone. This was the constraint the extension was
designed under, not a happy accident: a deployment either wants the socialised
structure or it does not, and the escrow must be identical either way.

The pool reuses the escrow's own idiom: repayment is `balanceOf`, not a ledger.
Same benefit (any provenance counts, no `fund` entrypoint), same consequence
(a transfer in is irreversible — up to the obligation, with the excess forwarded
to the escrow rather than returned to the sender).

### Draw-down burns proportionally, so notes need no checkpoints

The design problem: an LP drawing a *partial* repayment must not forfeit their
claim on the rest, but the obvious fix — per-holder dividend checkpoints settled
in a transfer hook — costs storage on every transfer and complicates a token whose
whole appeal is being a vanilla, tradeable ERC-20.

Instead `redeem` pays the pro-rata slice of available cash and burns only the
fraction of the notes that the cash repaid: `burn = ceil(assets * supply / owed)`.
Since repayment reduces the obligation 1:1, `owed / supply` comes out exactly
where it went in — the same price-neutrality `RecoveryEscrow.redeem` has, proved
the same way. That makes the pool stateless per holder: no checkpoints, no
transfer hook, no accrual bookkeeping per address, and the note stays a plain
ERC-20 (invariants P4, P5).

Rounding direction is deliberate and mirrors the escrow: `assets` floors and the
burn *ceils*, so the redeemer pays the dust and the obligation per note can only
ever move up for the holders who stay. Flooring the burn would leak value out of
the remaining notes.

A consequence worth stating: drawing down is first-come on *available cash*. An
LP who leaves cash in the pool may find a co-LP has drawn their fair share of it
first. Nobody's total entitlement changes — only how much of it is already
liquid — but it means the pool is a claim on a stream, not a bank account.

### Interest: touch-based accrual, hard cap

Accrual is Compound-style — linear between touches, compounding once per touch —
on the *outstanding* balance, so repaying early is genuinely cheaper. Two
consequences to state plainly rather than hide:

- `accrue()` is permissionless, so anyone (an LP, most obviously) can drive the
  compounding frequency arbitrarily high. The effective rate should therefore be
  priced as **continuously compounded**; that is its upper bound. An `expWad`
  index would make it touch-independent and was considered, but it costs gas and
  precision surface on every call to remove a wart the cap already bounds.
- `MAX_REPAYMENT_BPS` caps cumulative interest at deployment and forever. This is
  the same instinct as the spigot's immutable `[MIN, MAX]` share clamp: the
  protocol's total liability must be knowable at the moment it is incurred. It
  also stops an unpaid obligation compounding into a number nobody will ever
  service, which — absent a spigot — would be symbolic anyway.

`interestAccrued` is kept as storage even though the repo otherwise deleted its
running totals as telemetry. It is not telemetry: it is what the cap is measured
against. `principal` likewise anchors the cap.

### The credible-commitment gap

Deployed without a spigot, nothing on-chain compels repayment. The obligation the
pool tracks is an accounting record of a promise, and LPs underwrite that. This is
not a defect in the contract but it is a real property of the structure, and it
decides who will deposit: insiders or a protocol treasury socialising internally,
yes; external capital at a decent rate, unlikely. Pointing a `RevenueSpigot` at
the pool address closes the gap without any code change — and because the pool
becomes a pass-through once the notes are burned, a spigot left pointing at it
keeps benefiting claimants forever after (P7).

## Standing decisions carried over

- Claim `decimals == asset.decimals()`, so `ONE = 10**decimals` and all arithmetic
  is raw-unit.
- Constructor rejects `asset.decimals() > 18`.
- Floor division in `redeem`, `assets` computed pre-burn, price-neutral by
  construction — so no slippage parameter and no MEV surface (invariant I1).
- I1 monotonicity excludes the `supply == 0` terminal state (price is 0 there by
  definition; supply can never recover).
- Redeeming `amount == 0` reverts only in the dead state where `supply == 0`
  (0/0); otherwise it is a harmless no-op. Left unguarded to avoid adding a branch.
- Invariant violations that must fail the suite are recorded as ghost flags (I5, I6,
  I8, I9), because under `fail_on_revert = false` an inline assertion revert in a
  handler is swallowed. The handler is the escrow admin (it deploys the escrow) and
  receives the full supply, distributing to actors by transfer.

## Things deliberately not present

No merkle logic in this repo (distribution is external). No credited/uncredited
split, no sweep, no fund/mint, no redemption floor, coupon/accrual, par state,
lifecycle enum, pause, upgradeability, governance, multi-asset pool, or
maturity/conversion.

This describes the **claimant** side, and still does: `RecoveryClaim` has no
accrual and the escrow has no par state. `RecoveryPool` deliberately does carry an
accrual — that is the whole point of the LP structure, where the premium is a
function of how long repayment takes rather than something embedded in the
allocation at issuance. It is confined to the auxiliary contract and none of it
reaches the escrow. Still absent on the LP side too: maturity, default/liquidation,
conversion, transfer restrictions on the note, and any on-chain enforcement that
repayment actually happens.

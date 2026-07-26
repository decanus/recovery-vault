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

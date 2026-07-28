# Recovery Claim

A pot of a single ERC-20 asset, and a transferable token that is a pro-rata claim
on it. The **entire** claim supply is minted once, at construction, to the
creator, who distributes it off-chain — e.g. by funding a merkle-drop distributor
that `transfer`s tokens to loss-bearing addresses. Supply is finalised (redemption
opened) one-way. From then on the only holder action is:

```
redeem(amount) → burn `amount` of the claim token,
                 receive `amount × balance ÷ totalSupply` of the asset
```

Anyone holding the token can redeem. No proofs, no allowlist, no eligibility
check, no claim window. The token is fully transferable and the contract does not
care how you got it.

## Contracts

| Contract | Role |
|---|---|
| `RecoveryClaim` | Vanilla, fully transferable ERC-20. Full supply minted to the creator at construction; only `burn` (escrow-only, on redemption) ever changes supply after that. No `mint`. |
| `RecoveryEscrow` | Holds the pot and prices/settles redemptions. |
| `RevenueSpigot` | Independent. Intercepts a fixed, timelocked share of protocol revenue and forwards it to the escrow by transfer. |
| `RecoveryPool` | **Optional.** Socialises the cost to LPs: they fund the escrow up front and are repaid, with interest, out of protocol revenue. |
| `RecoveryNote` | The LP-side token — a pro-rata claim on that repayment obligation. Minted 1:1 on deposit, latched at close. |

The escrow deploys the claim token in its own constructor and mints the whole
supply to the creator (`msg.sender`) atomically. The binding is 1:1, immutable on
both sides — no post-deploy setter, no `initialize`, no CREATE2 precompute.

## The pot is the balance

`pricePerClaim` and `redeem` read `asset.balanceOf(address(this))` directly. **Any
asset that lands at the escrow — however it arrives — backs the claims and is
redeemable.** There is no credited/uncredited distinction, no `fund` entrypoint,
and no sweep.

```solidity
function pricePerClaim() public view returns (uint256) {
    uint256 supply = claim.totalSupply();
    if (supply == 0) return 0;
    return asset.balanceOf(address(this)) * ONE / supply;   // ONE = 10**decimals
}
```

This is safe because supply is fixed at construction (nobody deposits for shares,
so there is no ERC-4626-style inflation attack) and a transfer in only ever
**raises** the price pro-rata for every holder — a gift, not an attack.

**Consequence — read before deploying:** funding is just a transfer to the escrow
address, and it is irreversible. Anything sent there, including a mistaken or
accidental transfer, becomes claimant money with no way to recover it. Do not send
funds that are earmarked elsewhere or still subject to legal process; hold those
outside the escrow until they are unambiguously claimant property.

Redemption is **price-neutral**: a redeemer takes exactly their pro-rata share and
burns exactly their pro-rata claim, so the ratio is unchanged for everyone left.
Floor division means dust can only ever nudge the price up.

## Deployment & distribution ordering

Because 100% of the supply is minted to the creator, the creator transiently holds
every claim. Redemption is gated on `finalize()` precisely so a creator holding the
full supply cannot drain the pot before distributing. Order matters:

1. **Deploy** `RecoveryEscrow(asset, supply, name, symbol)` from the creator/admin
   key. Requires `asset.decimals() <= 18`. The claim token is deployed and the
   full `supply` minted to the creator automatically.
   - `script/Deploy.s.sol` (env: `ASSET`, `SUPPLY`, `CLAIM_NAME`, `CLAIM_SYMBOL`).
2. **Distribute** the claim tokens off-chain: build the loss-list merkle tree, fund
   an external distributor (e.g. [1inch/merkle-distribution](https://github.com/1inch/merkle-distribution))
   with the tokens, publish the root. Claimants `claim` their tokens (a transfer,
   not a mint) whenever they like.
3. **Fund** the pot by transferring the asset to the escrow address (or via the
   `RevenueSpigot`). Do this **after** distributing the claim tokens.
4. **`finalize()`** — one-way, irreversible. Opens redemption. `redeem` reverts
   until it is called.

The trust model: the creator is trusted with the full supply until it is
distributed, and the ordering above is a process discipline, not something the
contract can enforce beyond the `finalize` gate. For a recovery vehicle run by an
accountable administrator with a publicly verifiable merkle root, this is the
intended tradeoff for deleting all on-chain distribution machinery.

## Optional: socialising the cost to LPs

By default, claimants *are* the lenders — they hold a claim on a pot that fills
slowly from the spigot, and they carry the duration. `RecoveryPool` inverts that.
LPs put up the capital immediately, claimants are made whole on day one, and the
LPs hold the long-duration claim on protocol revenue instead.

```
LPs ──deposit──► RecoveryPool ──close()──► RecoveryEscrow ──redeem──► claimants (day 1)
                      ▲                          ▲
     protocol revenue ┘                          └── overflow, once LPs are repaid
        (plain transfer)
```

This is strictly **auxiliary**. `RecoveryEscrow`, `RecoveryClaim` and
`RevenueSpigot` are unchanged and know nothing about it — the escrow just sees
asset arrive, exactly as it would from any other funder. A deployment either
includes a pool or it does not.

**Lifecycle.** `deposit` mints notes 1:1 during the funding window, and
`withdraw` is unconditional while it is open (nothing is committed yet).
`close()` is admin-only and one-way: it ships the entire raise to the escrow in a
single transfer, latches minting, and starts interest running. No target is
enforced — a short raise simply funds the escrow partially, which prices its
claims correctly on its own. From then on repayment is, as everywhere in this
repo, **just a transfer to the pool address**: no `repay` entrypoint, no
credited/uncredited split.

**Interest** accrues on the *outstanding* obligation, so repaying early is
genuinely cheaper, and is bounded forever by `MAX_REPAYMENT_BPS` — at 15000 the
protocol can never owe more than 1.5× what it borrowed however long repayment
takes. That ceiling is the LP-side analogue of the spigot's immutable share
clamp. Accrual is linear between touches and `accrue()` is permissionless, so
**price the rate as continuously compounded** — that is its upper bound.

### Drawing down a partial repayment

The one non-obvious mechanism. An LP drawing revenue that only covers part of the
debt must not forfeit the rest, so `redeem` burns only the fraction of the notes
that the cash actually repaid:

```solidity
assets = n * cash / supply;              // floor — your pro-rata slice of available cash
burn   = ceilDiv(assets * supply, owed); // the fraction of your notes that cash repaid
owed  -= assets;                         // repayment reduces the obligation 1:1
```

Draw 60% of a half-covered pool and you burn 30% of the supply, keeping notes that
still claim the unpaid half. The obligation per note (`owed / supply`) is
**invariant** across a redemption — the direct sibling of the escrow's
price-neutral `redeem`, and the reason there is no slippage parameter or MEV
surface here either. `ceilDiv` on the burn means dust always favours the holders
who stay; the redeemer pays it. No per-holder checkpoints are involved, so notes
stay freely transferable and a secondary market can price the recovery.

Cash beyond the obligation is not LP money: `redeem` caps at what is owed, and the
permissionless `forwardExcess()` pushes the overflow on to the escrow. Once every
note is burned the pool is a pure pass-through to the claimants — the right
resting place for revenue that keeps arriving after the LPs are square.

**Read before using this.** Without a `RevenueSpigot` pointed at the pool, nothing
on-chain obliges anyone to repay it: the obligation tracked here is an accounting
record of a promise, not an enforceable lien, and LPs underwrite exactly that. If
you want the commitment to be credible, deploy a spigot with `escrow` set to the
pool address — its immutable `MIN_SHARE_BPS`, append-only sources and
permissionless `route` are what turn the promise into a mechanism, and the
pass-through terminal state means claimants inherit the flow once LPs are repaid.

## Constructor parameters

### `RecoveryEscrow(IERC20 asset, uint256 supply, string name, string symbol)`
- `asset` — the single pot asset. **Must** have `decimals() <= 18` (enforced) and
  **must not** be rebasing (a rebasing balance would silently reprice the pot;
  undetectable on-chain — a deployment requirement). Fee-on-transfer assets are
  harmless: the pot is read live, so whatever actually arrives is what backs the
  claims.
- `supply` — the total, fixed claim supply (the full liability), minted in its
  entirety to the deployer.
- `name`, `symbol` — claim token metadata. Its `decimals` is set to
  `asset.decimals()`, so one whole claim token maps to one whole asset unit.

### `RevenueSpigot(IERC20 asset, IRecoveryEscrow escrow, uint256 minShareBps, uint256 maxShareBps, uint256 initialShareBps)`
- `asset` — the revenue asset (must match the escrow's asset).
- `escrow` — receives the intercepted share (by direct transfer).
- `minShareBps` / `maxShareBps` — the fixed, forever-immutable clamp on the
  intercept share (`0 < min <= max <= 10000`). The admin can never drive the share
  outside this range, so the intercept can never be zeroed.
- `initialShareBps` — starting share, within `[min, max]`.
  `register(source)` (append-only), `route(source)` (permissionless), and the
  `queueShareChange → SHARE_TIMELOCK (2 days) → executeShareChange` flow manage it.
  Set `escrow` to a `RecoveryPool` address to make the LP repayment enforceable;
  the pool forwards the overflow to the real escrow once the LPs are repaid.

### `RecoveryPool(IERC20 asset, address escrow, uint256 rateBps, uint256 maxRepaymentBps, string name, string symbol)`
- `asset` — what LPs deposit and are repaid in. Same `decimals() <= 18` and
  non-rebasing requirements as the escrow, and it should match the escrow's asset
  since the raise is transferred straight there.
- `escrow` — receives the raise at `close()` and any over-repayment afterwards.
  The pool never calls into it; a plain transfer is the whole integration.
- `rateBps` — annual rate on the outstanding obligation, `0 < rateBps <= 10000`.
  Fixed forever.
- `maxRepaymentBps` — ceiling on total repayment as bps of principal, `>= 10000`
  (10000 means principal only, no interest). Fixed forever.
- `name`, `symbol` — note token metadata. Its `decimals` is set to
  `asset.decimals()`, so one whole note maps to one whole asset unit of principal.

## Off-chain requirements

- **Snapshot & dispute.** The loss list is settled entirely off-chain — publish a
  snapshot, run a dispute window, finalise the allocation, then build the merkle
  tree used to distribute the claim tokens.
- **Premium multiplier (coupon).** Compensation for time-to-repayment is handled at
  issuance: choose the total `supply` and per-address allocations to embed any
  premium. There is no on-chain accrual, face-value cap, or par state.
- **Non-rebasing asset (hard requirement).** Do not deploy against a rebasing asset.

## Build & test

```bash
forge build --sizes
forge test                 # default profile (fuzz 10k)
FOUNDRY_PROFILE=ci forge test   # ci profile (fuzz 50k, invariant 5k×500)
forge coverage --report summary
forge fmt --check
```

### Note on invariant run times

The invariants are checked after every handler call, so the spec's default
(`runs=1000, depth=200`) and CI (`runs=5000, depth=500`) profiles are CI-grade
long-running jobs. For a quick local check, sample with e.g.
`FOUNDRY_INVARIANT_RUNS=150 FOUNDRY_INVARIANT_DEPTH=250 forge test --match-path
test/invariant/Invariants.t.sol`. The pool has its own suite (P1–P9) in
`test/invariant/PoolInvariants.t.sol`; sample it the same way.

Stack: Solidity `0.8.26`, `via_ir = true`, optimizer runs `20000`, `solady`
(`ERC20`, `SafeTransferLib`, `ReentrancyGuard`), `forge-std`. Custom errors
throughout, no revert strings.

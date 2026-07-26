# Recovery Claim

A pot of a single ERC-20 asset, and a transferable token that is a pro-rata claim
on it. Loss-bearing addresses are minted a plain ERC-20 (`RecoveryClaim`). Supply
is finalised once, one-way. From then on the only holder action is:

```
redeem(amount) → burn `amount` of the claim token,
                 receive `amount × poolBalance ÷ totalSupply` of the asset
```

Anyone holding the token can redeem. No proofs, no allowlist, no eligibility
check, no claim window. The token is fully transferable and the contract does not
care how you got it.

## Contracts

| Contract | Role |
|---|---|
| `RecoveryClaim` | Vanilla, fully transferable ERC-20. Only the escrow may mint/burn. Minting latches shut at finalisation. |
| `RecoveryEscrow` | Holds the pot, owns the only mint/burn rights, and prices/settles redemptions. |
| `RevenueSpigot` | Independent. Intercepts a fixed, timelocked share of protocol revenue and funds the escrow. |

The escrow deploys the claim token in its own constructor, so the binding is 1:1,
immutable on both sides, and correct atomically — no post-deploy setter, no
`initialize`, no CREATE2 precompute, no front-runnable window.

## The load-bearing rule

`poolBalance` is an **internal ledger**. It is never `asset.balanceOf(escrow)`.

```solidity
uint256 public poolBalance;                                   // credited, redeemable
function uncredited() public view returns (uint256) {
    return asset.balanceOf(address(this)) - poolBalance;      // present, NOT redeemable
}
```

Assets arrive at this address by direct transfer — clawed-back funds, unfrozen
exchange balances, law-enforcement returns — often with no warning, and some of it
is subject to ongoing legal process or owed elsewhere. **Arrival is not a
crediting decision.** Funds that land here are *uncredited* and pay out to nobody
until an admin calls `creditUncredited`. `poolBalance` rises only in `fund` and
`creditUncredited`, and falls only in `redeem`. Nothing else ever touches it.

A direct transfer therefore does not move `pricePerClaim()`; it only grows
`uncredited()`. (Invariant I5 is the cheapest test that proves the price reads the
ledger, not `balanceOf`.)

## Pricing

```solidity
function pricePerClaim() public view returns (uint256) {
    uint256 supply = claim.totalSupply();
    if (supply == 0) return 0;
    return poolBalance * ONE / supply;   // ONE = 10 ** asset.decimals()
}
```

Both terms are live: `poolBalance` (already reduced by every prior payout) over
`claim.totalSupply()` (already reduced by every prior burn). Redemption is
**price-neutral** — a redeemer takes exactly their pro-rata share and burns
exactly their pro-rata claim, so the ratio is unchanged for everyone left. Only
inflows (`fund`, `creditUncredited`) move the price up. Floor division means dust
can concentrate on remaining holders, which nudges the price *up*, never down.

`totalInflows`, `totalPayouts`, `totalSwept` are accounting history for the
conservation invariant and public progress reporting only. They never appear in
`pricePerClaim` or `redeem`.

## Deployment & distribution ordering

1. **Deploy** `RecoveryEscrow(asset, name, symbol)` from the admin key. Requires
   `asset.decimals() <= 18`. The claim token is deployed automatically.
   - `script/Deploy.s.sol` (env: `ASSET`, `CLAIM_NAME`, `CLAIM_SYMBOL`).
2. **Distribute** the loss list, in batches, while unfinalised. Callable
   repeatedly; duplicate addresses accumulate. `correct(from, to, amount)` fixes
   errors found after a batch lands, without changing total supply.
   - `script/Distribute.s.sol` reads a CSV of `address,amount` (raw units, no
     header) and drives batched `distribute` calls (env: `ESCROW`, `CSV`,
     `BATCH_SIZE`).
3. **Fund** the pot via `fund(amount)` (permissionless, pulls the asset) and/or by
   crediting arrivals with `creditUncredited(amount)`.
4. **`finalize()`** — one-way, irreversible. After it: no mint, no admin burn,
   supply is monotonically non-increasing, and `redeem` becomes available.
   `redeem` reverts while unfinalised.

Funding and distribution may interleave before finalisation. Redemption is only
enabled after finalisation, when `totalSupply` equals the true liability.

## Constructor parameters

### `RecoveryEscrow(IERC20 asset, string name, string symbol)`
- `asset` — the single pot asset. **Must** have `decimals() <= 18` (enforced),
  **must not** be fee-on-transfer (rejected at `fund` time by a pre/post balance
  check), and **must not** be rebasing (see below).
- `name`, `symbol` — metadata for the deployed claim token. Its `decimals` is set
  to `asset.decimals()`, so one whole claim token maps to one whole asset unit and
  all arithmetic is raw-unit.

### `RevenueSpigot(IERC20 asset, IRecoveryEscrow escrow, uint256 minShareBps, uint256 maxShareBps, uint256 initialShareBps)`
- `asset` — the revenue asset (must match the escrow's asset).
- `escrow` — the escrow that receives the intercepted share.
- `minShareBps` / `maxShareBps` — the fixed, forever-immutable clamp on the
  intercept share. `0 < min <= max <= 10000`. The admin can never drive the share
  outside this range, even after the timelock, so the intercept can never be
  zeroed.
- `initialShareBps` — starting share, within `[min, max]`.
  `register(source)` (append-only), `route(source)` (permissionless), and the
  `queueShareChange → SHARE_TIMELOCK (2 days) → executeShareChange` flow manage it.

## Off-chain requirements

- **Snapshot derivation.** The loss list is settled entirely off-chain: publish a
  snapshot of loss-bearing addresses and amounts, derived from the incident's
  ledger. The chain records only the resulting allocations.
- **Dispute process.** Run a dispute window against the published snapshot before
  writing allocations. Apply resolutions via `correct` (post-batch) up until
  `finalize`.
- **Premium multiplier (coupon).** Compensation for time-to-repayment is handled
  *at issuance*, not in code: mint a premium (e.g. 1.05 claim tokens per dollar
  lost) and set the funding target accordingly. There is no on-chain time-based
  accrual, face-value cap, or par state by design.
- **Non-rebasing asset (hard requirement).** A rebasing asset silently changes
  `asset.balanceOf(escrow)` out from under the ledger, breaking the
  credited/uncredited separation. This cannot be detected on-chain; **do not
  deploy against a rebasing asset.** Fee-on-transfer assets are rejected
  automatically by `fund`.

## Build & test

```bash
forge build --sizes
forge test                 # default profile (fuzz 10k)
FOUNDRY_PROFILE=ci forge test   # ci profile (fuzz 50k, invariant 5k×500)
forge coverage --report summary
forge fmt --check
forge test --match-contract GasBenchTest -vv   # distribute gas at 50/100/250
```

### `distribute` gas (size the batches against the chain's block gas limit)

| Batch size | Gas | ~per allocation |
|---|---|---|
| 50 | ~1.39M | ~27.9k |
| 100 | ~2.75M | ~27.5k |
| 250 | ~6.83M | ~27.3k |

Roughly linear at ~27.5k gas per allocation (first mint to a fresh address).
On a 30M-gas block, a batch of ~1000 fits with margin; pick a batch size well
under the target chain's limit.

### Note on invariant run times

The 9 invariants are checked after every handler call, so the spec's default
(`runs=1000, depth=200`) and CI (`runs=5000, depth=500`) profiles are CI-grade
long-running jobs. For a quick local check, sample with e.g.
`FOUNDRY_INVARIANT_RUNS=150 FOUNDRY_INVARIANT_DEPTH=250 forge test --match-path
test/invariant/Invariants.t.sol`.

Stack: Solidity `0.8.26`, `via_ir = true`, optimizer runs `20000`, `solady`
(`ERC20`, `SafeTransferLib`, `ReentrancyGuard`), `forge-std`. Custom errors
throughout, no revert strings.

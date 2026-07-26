// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { RecoveryEscrow } from "../../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../../src/RecoveryClaim.sol";
import { IERC20 } from "../../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

/// @title EscrowHandler
/// @notice Drives the escrow through pre- and post-finalisation states and can
///         drain the pot to `totalSupply == 0`. The handler *is* the escrow admin
///         (it deploys the escrow) and receives the full claim supply at
///         construction, which it distributes to actors by transfer — mirroring
///         the real flow (mint-all-to-creator, then distribute off-chain).
///         The pot is `asset.balanceOf(escrow)`; funding is just a transfer in.
/// @dev    Violations that must fail the suite are recorded as ghost flags rather
///         than asserted inline — under `fail_on_revert = false` an inline revert
///         from a failed assertion would be swallowed as "just another reverting
///         call". The `Invariants` contract asserts the flags.
contract EscrowHandler is CommonBase, StdCheats, StdUtils {
    RecoveryEscrow public immutable escrow;
    RecoveryClaim public immutable claim;
    MockERC20 public immutable asset;
    uint256 internal immutable ONE;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000;

    address[8] public actors;

    // ── Ghost accounting ────────────────────────────────────────────────────
    uint256 public ghost_inflows; // total asset ever sent into the escrow
    uint256 public ghost_payouts; // total asset ever redeemed out
    uint256 public ghost_finalizedAt;
    uint256 public ghost_maxSupplyBurned;

    // ── Coverage ghosts ─────────────────────────────────────────────────────
    uint256 public ghost_supplyAtFinalize;
    bool public ghost_reachedZeroSupply;
    uint256 public ghost_preFinalizeRedeemAttempts;
    bool public ghost_bigHolderRedeemedInFull;

    // ── Violation flags (asserted by Invariants) ────────────────────────────
    bool public flag_i5_fundingLoweredPrice;
    bool public flag_i6_redeemBeforeFinalize;
    bool public flag_i8_overPayout;
    bool public flag_i8_notDrained;
    bool public flag_i9_claimableFell;

    // ── Revert-rate accounting ──────────────────────────────────────────────
    uint256 public totalActions;
    uint256 public totalReverts;

    constructor() {
        asset = new MockERC20("USD Coin", "USDC", 6);
        escrow =
            new RecoveryEscrow(IERC20(address(asset)), TOTAL_SUPPLY, "Recovery Claim", "rcUSDC");
        claim = escrow.claim();
        ONE = escrow.ONE();

        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }

        // Distribute the full supply to actors by transfer (materially varied):
        // actor0 holds > 40%; actor7 holds exactly 1 wei.
        uint256[8] memory amt = [
            uint256(450_000_000),
            200_000_000,
            150_000_000,
            100_000_000,
            60_000_000,
            30_000_000,
            9_999_999,
            1
        ];
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            claim.transfer(actors[i], amt[i]);
            sum += amt[i];
        }
        // The allocation must consume the whole supply, or the handler would keep
        // a residual it could redeem — silently changing what the campaign covers.
        require(sum == TOTAL_SUPPLY, "allocation != TOTAL_SUPPLY");
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 8];
    }

    function _price() internal view returns (uint256) {
        return escrow.pricePerClaim();
    }

    /// @dev Claimable at a given price. The price is identical across all actors
    ///      at any instant, so callers pass it in rather than re-reading it 8×.
    function _claimableAt(address who, uint256 price) internal view returns (uint256) {
        return claim.balanceOf(who) * price / ONE;
    }

    function _postFinalizeSupplyBookkeeping() internal {
        if (!escrow.finalized()) return;
        uint256 supply = claim.totalSupply();
        uint256 burned = ghost_supplyAtFinalize - supply;
        if (burned > ghost_maxSupplyBurned) ghost_maxSupplyBurned = burned;
        if (supply == 0) ghost_reachedZeroSupply = true;
    }

    // ── actions ─────────────────────────────────────────────────────────────

    function finalizeSupply() external {
        totalActions++;
        if (escrow.finalized()) return;
        try escrow.finalize() {
            ghost_finalizedAt = block.number == 0 ? 1 : block.number;
            ghost_supplyAtFinalize = claim.totalSupply();
        } catch {
            totalReverts++;
        }
    }

    /// @dev Fund the pot by transferring asset straight into the escrow. This is
    ///      the only funding path now, and it raises the price — a gift to all
    ///      holders. I5: it must never *lower* the price.
    function fundPot(uint256 amt) external {
        totalActions++;
        uint256 m = bound(amt, 1, 1_000_000_000);
        asset.mint(address(this), m);
        uint256 pBefore = _price();
        asset.transfer(address(escrow), m);
        ghost_inflows += m;
        if (_price() < pBefore) flag_i5_fundingLoweredPrice = true;
    }

    function transferClaim(uint256 seed, uint256 amt) external {
        totalActions++;
        address from = _actor(seed);
        address to = _actor(seed >> 8);
        uint256 bal = claim.balanceOf(from);
        if (bal == 0) return;
        uint256 m = bound(amt, 0, bal);
        vm.prank(from);
        try claim.transfer(to, m) { }
        catch {
            totalReverts++;
        }
    }

    function redeem(uint256 seed, uint256 amtSeed) external {
        totalActions++;
        uint256 idx = seed % 8;
        address who = actors[idx];
        uint256 bal = claim.balanceOf(who);

        // Bias the amount toward the extremes: 0, 1 wei, or full balance.
        uint256 amt;
        uint256 mode = amtSeed % 4;
        if (mode == 0) amt = 0;
        else if (mode == 1) amt = bal == 0 ? 0 : 1;
        else if (mode == 2) amt = bal; // full exit

        else amt = bound(amtSeed, 0, bal);

        if (!escrow.finalized()) {
            // I6: redeem MUST revert while not finalized.
            ghost_preFinalizeRedeemAttempts++;
            vm.prank(who);
            try escrow.redeem(amt, who) {
                flag_i6_redeemBeforeFinalize = true;
            } catch {
                totalReverts++;
            }
            return;
        }

        if (bal == 0 && amt == 0) {
            // Would divide 0/0 only if supply==0; otherwise 0 payout no-op.
            if (claim.totalSupply() == 0) return;
        }

        uint256 supplyBefore = claim.totalSupply();
        uint256 balBefore = asset.balanceOf(address(escrow));

        // Snapshot every non-redeeming actor's claimable at the pre-call price.
        // priceBefore == pricePerClaim() here, derived from locals we already hold
        // (supplyBefore > 0, since supply == 0 was handled above).
        uint256 priceBefore = balBefore * ONE / supplyBefore;
        uint256[8] memory claimableBefore;
        for (uint256 i; i < 8; ++i) {
            if (actors[i] != who) claimableBefore[i] = _claimableAt(actors[i], priceBefore);
        }

        vm.prank(who);
        try escrow.redeem(amt, who) returns (uint256 assets) {
            // I8: no redeemer extracts more than exact pro-rata share.
            if (assets * supplyBefore > amt * balBefore) flag_i8_overPayout = true;

            // I8 paired: the redemption that empties supply drains the pot.
            if (claim.totalSupply() == 0 && asset.balanceOf(address(escrow)) != 0) {
                flag_i8_notDrained = true;
            }

            // I9: no non-redeeming actor's claimable fell across this call.
            uint256 priceAfter = escrow.pricePerClaim();
            for (uint256 i; i < 8; ++i) {
                if (actors[i] != who) {
                    if (_claimableAt(actors[i], priceAfter) < claimableBefore[i]) {
                        flag_i9_claimableFell = true;
                    }
                }
            }

            ghost_payouts += assets;
            if (idx == 0 && amt == bal && bal != 0) ghost_bigHolderRedeemedInFull = true;
            _postFinalizeSupplyBookkeeping();
        } catch {
            totalReverts++;
        }
    }
}

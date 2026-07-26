// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { EscrowHandler } from "./handlers/EscrowHandler.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title Invariants
/// @notice The nine invariants of the escrow (build spec §7), each a named
///         `invariant_*`. Monotonicity invariants (I1, I4) track a persisted
///         previous value; violation-flag invariants (I5, I6, I8, I9) assert
///         ghost flags the handler sets without reverting.
contract Invariants is StdInvariant, Test {
    EscrowHandler internal handler;
    RecoveryEscrow internal escrow;
    RecoveryClaim internal claim;
    MockERC20 internal asset;

    // Monotonicity trackers.
    uint256 internal prevPrice_I1;
    bool internal seen_I1;
    uint256 internal prevSupply_I4;
    bool internal seen_I4;

    function setUp() public {
        handler = new EscrowHandler();
        escrow = handler.escrow();
        claim = handler.claim();
        asset = handler.asset();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = EscrowHandler.distributeBatch.selector;
        selectors[1] = EscrowHandler.correctAllocation.selector;
        selectors[2] = EscrowHandler.finalizeSupply.selector;
        selectors[3] = EscrowHandler.fund.selector;
        selectors[4] = EscrowHandler.donate.selector;
        selectors[5] = EscrowHandler.creditUncredited.selector;
        selectors[6] = EscrowHandler.sweepUncredited.selector;
        selectors[7] = EscrowHandler.redeem.selector;
        selectors[8] = EscrowHandler.transferClaim.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    // ── I1 ──────────────────────────────────────────────────────────────────
    /// Once finalized, `pricePerClaim()` is monotonically non-decreasing. The
    /// `supply == 0` terminal state prices at 0 by definition and is excluded —
    /// there is nothing left to price, and supply can never recover post-finalize.
    function invariant_I1_priceMonotonicPostFinalize() public {
        if (!escrow.finalized() || claim.totalSupply() == 0) return;
        uint256 p = escrow.pricePerClaim();
        if (seen_I1) assertGe(p, prevPrice_I1, "I1: price decreased post-finalize");
        prevPrice_I1 = p;
        seen_I1 = true;
    }

    // ── I2 ──────────────────────────────────────────────────────────────────
    function invariant_I2_solvency() public view {
        assertLe(escrow.poolBalance(), asset.balanceOf(address(escrow)), "I2: insolvent");
    }

    // ── I3 ──────────────────────────────────────────────────────────────────
    function invariant_I3_conservation() public view {
        assertEq(
            escrow.totalInflows(),
            escrow.totalPayouts() + escrow.totalSwept() + escrow.poolBalance(),
            "I3: conservation broken"
        );
    }

    // ── I4 ──────────────────────────────────────────────────────────────────
    function invariant_I4_supplyNonIncreasingPostFinalize() public {
        if (!escrow.finalized()) return;
        uint256 s = claim.totalSupply();
        if (seen_I4) assertLe(s, prevSupply_I4, "I4: supply increased post-finalize");
        prevSupply_I4 = s;
        seen_I4 = true;
    }

    // ── I5 ──────────────────────────────────────────────────────────────────
    function invariant_I5_donationDoesNotMovePrice() public view {
        assertFalse(handler.flag_i5_donationMovedPrice(), "I5: donation moved price");
    }

    // ── I6 ──────────────────────────────────────────────────────────────────
    function invariant_I6_redeemRevertsBeforeFinalize() public view {
        assertFalse(handler.flag_i6_redeemBeforeFinalize(), "I6: redeem succeeded pre-finalize");
    }

    // ── I7 ──────────────────────────────────────────────────────────────────
    /// Enumerated as a standalone deterministic test below
    /// (`test_I7_noSelectorReducesPrice`): asserting it per fuzz-call would just
    /// restate I1, whereas §I7 asks that *every* selector be enumerated.
    function invariant_I7_placeholder() public pure {
        assertTrue(true);
    }

    // ── I8 ──────────────────────────────────────────────────────────────────
    function invariant_I8_noOverPayout() public view {
        assertFalse(handler.flag_i8_overPayout(), "I8: redeemer over-paid");
        assertFalse(handler.flag_i8_notDrained(), "I8: pot not drained at supply 0");
    }

    // ── I9 ──────────────────────────────────────────────────────────────────
    function invariant_I9_othersClaimableNonDecreasing() public view {
        assertFalse(handler.flag_i9_claimableFell(), "I9: a bystander's claimable fell");
    }

    // ── Coverage & revert-rate (build spec §7.1) ────────────────────────────
    function afterInvariant() public view {
        // Handler reached both pre- and post-finalisation, and full supply burn.
        assertGt(handler.ghost_finalizedAt(), 0, "handler never finalized");
        assertTrue(handler.ghost_reachedZeroSupply(), "handler never drained supply to 0");
        assertGt(handler.ghost_preFinalizeRedeemAttempts(), 0, "I6 never exercised pre-finalize");
        assertTrue(handler.ghost_bigHolderRedeemedInFull(), ">40% holder never fully exited");
        assertGt(handler.ghost_maxSupplyBurned(), 0, "no supply ever burned");

        // Revert rate under 40% — otherwise a handler that reverts on everything
        // would pass vacuously.
        uint256 actions = handler.totalActions();
        if (actions > 0) {
            assertLt(handler.totalReverts() * 100, actions * 40, "handler revert rate >= 40%");
        }
        console.log("actions", actions);
        console.log("reverts", handler.totalReverts());
        console.log("maxSupplyBurned", handler.ghost_maxSupplyBurned());
    }

    // ── I7: enumerate every external/public escrow selector ─────────────────
    /// No selector on the escrow reduces `pricePerClaim()`. Post-finalisation the
    /// mutating surface is `fund`, `creditUncredited`, `sweepUncredited`,
    /// `redeem` (distribute/correct/finalize revert); views never mutate. Each is
    /// invoked and the price is checked to be non-decreasing.
    function test_I7_noSelectorReducesPrice() public {
        // Build a finalized, funded, multi-holder state on a fresh escrow.
        MockERC20 a = new MockERC20("USD Coin", "USDC", 6);
        RecoveryEscrow e = new RecoveryEscrow(IERC20(address(a)), "Recovery Claim", "rcUSDC");
        RecoveryClaim c = e.claim();

        address h1 = address(0x111);
        address h2 = address(0x222);
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        to[0] = h1;
        amt[0] = 60_000_000;
        to[1] = h2;
        amt[1] = 40_000_000;
        e.distribute(to, amt);

        a.mint(address(this), 50_000_000);
        a.approve(address(e), 50_000_000);
        e.fund(50_000_000);
        e.finalize();

        uint256 p;

        // --- mutating selectors that revert post-finalize (price unchanged) ---
        p = e.pricePerClaim();
        try e.distribute(to, amt) { } catch { }
        assertGe(e.pricePerClaim(), p, "I7: distribute reduced price");

        p = e.pricePerClaim();
        try e.correct(h1, h2, 1) { } catch { }
        assertGe(e.pricePerClaim(), p, "I7: correct reduced price");

        p = e.pricePerClaim();
        try e.finalize() { } catch { }
        assertGe(e.pricePerClaim(), p, "I7: finalize reduced price");

        // --- fund: increases ---
        p = e.pricePerClaim();
        a.mint(address(this), 10_000_000);
        a.approve(address(e), 10_000_000);
        e.fund(10_000_000);
        assertGe(e.pricePerClaim(), p, "I7: fund reduced price");

        // --- donation + creditUncredited: increases ---
        p = e.pricePerClaim();
        a.mint(address(this), 5_000_000);
        a.transfer(address(e), 5_000_000);
        assertEq(e.pricePerClaim(), p, "I7: donation moved price");
        e.creditUncredited(5_000_000);
        assertGe(e.pricePerClaim(), p, "I7: credit reduced price");

        // --- sweepUncredited: price unchanged ---
        a.mint(address(this), 3_000_000);
        a.transfer(address(e), 3_000_000);
        p = e.pricePerClaim();
        e.sweepUncredited(address(0xdead), 3_000_000);
        assertEq(e.pricePerClaim(), p, "I7: sweep moved price");

        // --- redeem: non-decreasing ---
        p = e.pricePerClaim();
        vm.prank(h1);
        e.redeem(30_000_000, h1);
        assertGe(e.pricePerClaim(), p, "I7: redeem reduced price");

        // --- claim.transfer does not touch escrow price ---
        p = e.pricePerClaim();
        vm.prank(h2);
        c.transfer(h1, 10_000_000);
        assertEq(e.pricePerClaim(), p, "I7: claim transfer moved price");
    }
}

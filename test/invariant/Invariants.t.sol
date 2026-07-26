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
/// @notice The core invariants of the balance-backed escrow, each a named
///         `invariant_*`. Monotonicity invariants (price, supply) track a
///         persisted previous value; violation-flag invariants assert ghost flags
///         the handler sets without reverting. Conservation is tracked via the
///         handler's ghosts. "No selector reduces the price" is enumerated in the
///         standalone `test_I7_noSelectorReducesPrice`.
contract Invariants is StdInvariant, Test {
    EscrowHandler internal handler;
    RecoveryEscrow internal escrow;
    RecoveryClaim internal claim;
    MockERC20 internal asset;

    uint256 internal prevPrice_I1;
    bool internal seen_I1;
    uint256 internal prevSupply_I4;
    bool internal seen_I4;

    function setUp() public {
        handler = new EscrowHandler();
        escrow = handler.escrow();
        claim = handler.claim();
        asset = handler.asset();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = EscrowHandler.finalizeSupply.selector;
        selectors[1] = EscrowHandler.fundPot.selector;
        selectors[2] = EscrowHandler.redeem.selector;
        selectors[3] = EscrowHandler.transferClaim.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    // ── I1 ──────────────────────────────────────────────────────────────────
    /// Once finalized, `pricePerClaim()` is monotonically non-decreasing. The
    /// `supply == 0` terminal state prices at 0 by definition and is excluded.
    function invariant_I1_priceMonotonicPostFinalize() public {
        if (!escrow.finalized() || claim.totalSupply() == 0) return;
        uint256 p = escrow.pricePerClaim();
        if (seen_I1) assertGe(p, prevPrice_I1, "I1: price decreased post-finalize");
        prevPrice_I1 = p;
        seen_I1 = true;
    }

    // ── I2 ──────────────────────────────────────────────────────────────────
    /// Solvency: the sum of every holder's individually-claimable amount never
    /// exceeds the pot. Summing per-actor floors (rather than the aggregate) is
    /// what gives this teeth — it would catch a `pricePerClaim` that over-reports.
    function invariant_I2_solvency() public view {
        uint256 one = escrow.ONE();
        uint256 price = escrow.pricePerClaim();
        uint256 sumClaimable;
        for (uint256 i; i < 8; ++i) {
            sumClaimable += claim.balanceOf(handler.actors(i)) * price / one;
        }
        assertLe(sumClaimable, asset.balanceOf(address(escrow)), "I2: over-promised");
    }

    // ── I3 ──────────────────────────────────────────────────────────────────
    /// Conservation: everything sent in is either still in the pot or paid out.
    function invariant_I3_conservation() public view {
        assertEq(
            handler.ghost_inflows(),
            handler.ghost_payouts() + asset.balanceOf(address(escrow)),
            "I3: conservation broken"
        );
    }

    // ── I4 ──────────────────────────────────────────────────────────────────
    /// Supply is fixed at construction and only ever decreases via burn.
    function invariant_I4_supplyNonIncreasing() public {
        uint256 s = claim.totalSupply();
        if (seen_I4) assertLe(s, prevSupply_I4, "I4: supply increased");
        prevSupply_I4 = s;
        seen_I4 = true;
    }

    // ── I5 ──────────────────────────────────────────────────────────────────
    /// Funding is just a transfer into the escrow; it raises the price for
    /// everyone (a gift) and must never lower it. This is the deliberate inverse
    /// of a credited-ledger design: donations here are intended, not attacks.
    function invariant_I5_fundingNeverLowersPrice() public view {
        assertFalse(handler.flag_i5_fundingLoweredPrice(), "I5: funding lowered price");
    }

    // ── I6 ──────────────────────────────────────────────────────────────────
    function invariant_I6_redeemRevertsBeforeFinalize() public view {
        assertFalse(handler.flag_i6_redeemBeforeFinalize(), "I6: redeem succeeded pre-finalize");
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

    // ── Coverage & revert-rate ──────────────────────────────────────────────
    /// @dev Coverage is reported, not asserted. Whether the fuzzer reaches a
    ///      specific state (full drain, big-holder exit) in a given campaign
    ///      depends on the seed and on Foundry's cross-run state semantics, which
    ///      differ by version — asserting it makes CI flaky. The states that
    ///      matter are proven deterministically in the unit tests
    ///      (e.g. `test_rounding_lastHolderDrainsNoDivByZero`,
    ///      `test_othersRedemption_claimableNonDecreasing_fullExit`,
    ///      `test_redeem_revertsPreFinalizationEvenIfFunded`). Only the
    ///      revert-rate — a ratio that holds regardless of which states are hit —
    ///      is asserted, so a handler that reverts on everything still fails.
    function afterInvariant() public view {
        uint256 actions = handler.totalActions();
        if (actions > 0) {
            assertLt(handler.totalReverts() * 100, actions * 40, "handler revert rate >= 40%");
        }
        console.log("actions        ", actions);
        console.log("reverts        ", handler.totalReverts());
        console.log("finalizedAt    ", handler.ghost_finalizedAt());
        console.log("preFinalRedeem ", handler.ghost_preFinalizeRedeemAttempts());
        console.log("maxSupplyBurned", handler.ghost_maxSupplyBurned());
        console.log("reachedZero    ", handler.ghost_reachedZeroSupply());
        console.log("bigHolderExit  ", handler.ghost_bigHolderRedeemedInFull());
    }

    // ── I7: enumerate every external/public escrow selector ─────────────────
    /// No selector on the escrow reduces `pricePerClaim()`. The mutating surface
    /// is just `finalize` and `redeem`; views never mutate; funding is a plain
    /// asset transfer (raises the price). Each is invoked and checked.
    function test_I7_noSelectorReducesPrice() public {
        MockERC20 a = new MockERC20("USD Coin", "USDC", 6);
        RecoveryEscrow e =
            new RecoveryEscrow(IERC20(address(a)), 100_000_000, "Recovery Claim", "rcUSDC");
        RecoveryClaim c = e.claim();

        address h1 = address(0x111);
        address h2 = address(0x222);
        c.transfer(h1, 60_000_000);
        c.transfer(h2, 40_000_000);

        // fund by transfer, then open
        a.mint(address(this), 50_000_000);
        a.transfer(address(e), 50_000_000);
        e.finalize();

        uint256 p;

        // finalize reverts once finalized (price unchanged)
        p = e.pricePerClaim();
        try e.finalize() { } catch { }
        assertGe(e.pricePerClaim(), p, "I7: finalize reduced price");

        // funding (transfer in): raises price
        p = e.pricePerClaim();
        a.mint(address(this), 10_000_000);
        a.transfer(address(e), 10_000_000);
        assertGe(e.pricePerClaim(), p, "I7: funding reduced price");

        // redeem: non-decreasing
        p = e.pricePerClaim();
        vm.prank(h1);
        e.redeem(30_000_000, h1);
        assertGe(e.pricePerClaim(), p, "I7: redeem reduced price");

        // claim.transfer does not touch escrow price
        p = e.pricePerClaim();
        vm.prank(h2);
        c.transfer(h1, 10_000_000);
        assertEq(e.pricePerClaim(), p, "I7: claim transfer moved price");
    }
}

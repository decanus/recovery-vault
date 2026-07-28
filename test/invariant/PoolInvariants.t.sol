// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { PoolHandler } from "./handlers/PoolHandler.sol";
import { RecoveryPool } from "../../src/RecoveryPool.sol";
import { RecoveryNote } from "../../src/RecoveryNote.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title PoolInvariants
/// @notice The core invariants of the LP pool, each a named `invariant_P*`. Same
///         conventions as `Invariants`: monotonicity invariants persist a previous
///         value, violation-flag invariants assert ghosts the handler sets without
///         reverting, and coverage is reported rather than asserted.
contract PoolInvariants is StdInvariant, Test {
    PoolHandler internal handler;
    RecoveryPool internal pool;
    RecoveryNote internal note;
    RecoveryEscrow internal escrow;
    MockERC20 internal asset;

    uint256 internal prevOwedPerNote_P4;
    bool internal seen_P4;
    uint256 internal prevSupply_P6;
    bool internal seen_P6;

    function setUp() public {
        handler = new PoolHandler();
        pool = handler.pool();
        note = handler.note();
        escrow = handler.escrow();
        asset = handler.asset();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = PoolHandler.deposit.selector;
        selectors[1] = PoolHandler.withdraw.selector;
        selectors[2] = PoolHandler.close.selector;
        selectors[3] = PoolHandler.repay.selector;
        selectors[4] = PoolHandler.advanceTime.selector;
        selectors[5] = PoolHandler.accrue.selector;
        selectors[6] = PoolHandler.redeem.selector;
        selectors[7] = PoolHandler.forwardExcess.selector;
        selectors[8] = PoolHandler.transferNote.selector;
        selectors[9] = PoolHandler.dischargeAll.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    // ── P1 ──────────────────────────────────────────────────────────────────
    /// Obligation conservation, exactly: everything the protocol has ever owed is
    /// either still outstanding, already paid to LPs, or written off as dust when
    /// the last note burned.
    function invariant_P1_obligationConservation() public view {
        if (!pool.closed()) return;
        assertEq(
            handler.ghost_paidToLPs() + pool.debt() + handler.ghost_writtenOff(),
            pool.principal() + pool.interestAccrued(),
            "P1: obligation not conserved"
        );
    }

    // ── P2 ──────────────────────────────────────────────────────────────────
    /// The repayment ceiling holds however long repayment takes: LPs can never be
    /// paid more than principal plus capped interest, and interest itself never
    /// exceeds the cap. This is the LP-side analogue of the spigot's immutable
    /// share clamp — the protocol's total liability is bounded at deployment.
    function invariant_P2_repaymentCap() public view {
        if (!pool.closed()) return;
        assertLe(pool.interestAccrued(), pool.maxInterest(), "P2: interest exceeded cap");
        assertLe(
            handler.ghost_paidToLPs(),
            pool.principal() * 13_000 / 10_000,
            "P2: paid beyond principal + capped interest"
        );
    }

    // ── P3 ──────────────────────────────────────────────────────────────────
    /// The window is one-way: no draw-down before the raise is committed to the
    /// escrow, and no deposit after.
    function invariant_P3_windowIsOneWay() public view {
        assertFalse(handler.flag_p3_redeemBeforeClose(), "P3: redeemed before close");
        assertFalse(handler.flag_p3_depositAfterClose(), "P3: deposited after close");
    }

    // ── P4 ──────────────────────────────────────────────────────────────────
    /// Once closed, the obligation per note is monotonically non-decreasing: it
    /// rises with interest and is left exactly where it was by a draw-down, so
    /// redeeming early neither dilutes nor enriches anyone. The `supply == 0`
    /// terminal state is 0 by definition and excluded.
    function invariant_P4_obligationPerNoteMonotonic() public {
        assertFalse(handler.flag_p4_obligationFell(), "P4: draw-down moved the obligation");
        if (!pool.closed() || note.totalSupply() == 0) return;
        uint256 o = pool.owedPerNote();
        if (seen_P4) assertGe(o, prevOwedPerNote_P4, "P4: obligation per note fell");
        prevOwedPerNote_P4 = o;
        seen_P4 = true;
    }

    // ── P5 ──────────────────────────────────────────────────────────────────
    /// A redeemer never burns more notes than they offered, and `previewRedeem`
    /// always agrees with what `redeem` actually does in the same block.
    function invariant_P5_redeemIsHonest() public view {
        assertFalse(handler.flag_p5_burnExceededOffer(), "P5: burned more notes than offered");
        assertFalse(handler.flag_p5_previewMismatch(), "P5: preview disagreed with execution");
    }

    // ── P6 ──────────────────────────────────────────────────────────────────
    /// Once minting is latched, note supply only ever decreases.
    function invariant_P6_supplyNonIncreasingPostClose() public {
        if (!note.mintingClosed()) return;
        uint256 s = note.totalSupply();
        if (seen_P6) assertLe(s, prevSupply_P6, "P6: supply increased after latch");
        prevSupply_P6 = s;
        seen_P6 = true;
    }

    // ── P7 ──────────────────────────────────────────────────────────────────
    /// The pool is strictly additive for claimants. It sends the escrow the raise
    /// and later the overflow, and has no way to pull anything back out — so the
    /// escrow's pot never falls on the pool's account.
    function invariant_P7_escrowNeverLosesGround() public view {
        assertFalse(handler.flag_p7_escrowLostGround(), "P7: escrow lost ground to a draw-down");
        assertEq(
            asset.balanceOf(address(escrow)),
            handler.ghost_toEscrow(),
            "P7: escrow balance diverged from what the pool sent"
        );
    }

    // ── P8 ──────────────────────────────────────────────────────────────────
    /// Asset conservation across the whole system: everything deposited or repaid
    /// is either still in the pool, back with an LP, or gone to the escrow.
    function invariant_P8_assetConservation() public view {
        assertEq(
            handler.ghost_deposited() + handler.ghost_repaid(),
            handler.ghost_withdrawn() + handler.ghost_paidToLPs() + handler.ghost_toEscrow()
                + asset.balanceOf(address(pool)),
            "P8: asset conservation broken"
        );
    }

    // ── P9 ──────────────────────────────────────────────────────────────────
    /// Solvency: what LPs can collectively draw right now never exceeds the cash
    /// actually sitting in the pool. Summing per-actor floors is what gives this
    /// teeth — it would catch a `cashPerNote` that over-reports.
    function invariant_P9_solvency() public view {
        if (!pool.closed()) return;
        uint256 one = pool.ONE();
        uint256 perNote = pool.cashPerNote();
        uint256 sumDrawable;
        for (uint256 i; i < 8; ++i) {
            sumDrawable += note.balanceOf(handler.actors(i)) * perNote / one;
        }
        assertLe(sumDrawable, asset.balanceOf(address(pool)), "P9: over-promised to LPs");
    }

    // ── Coverage & revert-rate ──────────────────────────────────────────────
    /// @dev As in `Invariants`: coverage is reported, not asserted, because which
    ///      states a campaign reaches depends on the seed and on Foundry's
    ///      cross-run semantics. The states that matter are pinned
    ///      deterministically in `test/unit/RecoveryPool.t.sol`
    ///      (`test_fullRepaymentLifecycle`, `test_accrue_capsAtMaxRepayment`,
    ///      `test_forwardExcess_passesThroughOnceDischarged`). Only the revert
    ///      rate is asserted.
    function afterInvariant() public view {
        uint256 actions = handler.totalActions();
        if (actions > 0) {
            assertLt(handler.totalReverts() * 100, actions * 40, "handler revert rate >= 40%");
        }
        console.log("actions         ", actions);
        console.log("reverts         ", handler.totalReverts());
        console.log("closedAt        ", handler.ghost_closedAt());
        console.log("principal       ", pool.principal());
        console.log("paidToLPs       ", handler.ghost_paidToLPs());
        console.log("toEscrow        ", handler.ghost_toEscrow());
        console.log("preCloseRedeem  ", handler.ghost_preCloseRedeemAttempts());
        console.log("postCloseDeposit", handler.ghost_postCloseDepositAttempts());
        console.log("reachedZero     ", handler.ghost_reachedZeroSupply());
        console.log("reachedCap      ", handler.ghost_reachedCap());
        console.log("fullyCovered    ", handler.ghost_fullyCovered());
    }
}

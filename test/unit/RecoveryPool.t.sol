// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryPool } from "../../src/RecoveryPool.sol";
import { RecoveryNote } from "../../src/RecoveryNote.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev The LP side: deposits fund the escrow at `close()`, and the protocol
///      repays the pool with interest by plain transfer. A real escrow is wired
///      in as the beneficiary so the end-to-end path (LP capital → claimants,
///      revenue → LPs, overflow → claimants) is exercised, not mocked.
contract RecoveryPoolTest is BaseTest {
    RecoveryPool internal pool;
    RecoveryNote internal note;

    uint256 internal constant LIABILITY = 100_000_000; // 100 units, 6dp
    uint256 internal constant RATE_BPS = 1000; // 10% / yr
    uint256 internal constant CAP_BPS = 12_000; // 1.2x principal, ever

    function setUp() public override {
        super.setUp();
        _deploy(LIABILITY);
        pool = new RecoveryPool(
            IERC20(address(asset)), address(escrow), RATE_BPS, CAP_BPS, "Recovery Note", "rnUSDC"
        );
        note = pool.note();
    }

    /// @dev Fund `lp` and deposit into the open window.
    function _deposit(address lp, uint256 amount) internal {
        asset.mint(lp, amount);
        vm.startPrank(lp);
        asset.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Protocol revenue: a plain transfer to the pool. No entrypoint exists.
    function _repay(uint256 amount) internal {
        asset.mint(address(pool), amount);
    }

    // ── Construction ────────────────────────────────────────────────────────

    function test_construction_wiring() public view {
        assertEq(address(pool.asset()), address(asset));
        assertEq(pool.escrow(), address(escrow));
        assertEq(pool.admin(), admin);
        assertEq(note.pool(), address(pool));
        assertEq(note.decimals(), asset.decimals());
        assertEq(pool.ONE(), 1e6);
        assertEq(pool.RATE_BPS(), RATE_BPS);
        assertEq(pool.MAX_REPAYMENT_BPS(), CAP_BPS);
        assertFalse(pool.closed());
        assertFalse(note.mintingClosed());
        assertEq(note.totalSupply(), 0);
    }

    function test_construction_rejectsHighDecimals() public {
        MockERC20 bad = new MockERC20("Big", "BIG", 19);
        vm.expectRevert(RecoveryPool.DecimalsTooHigh.selector);
        new RecoveryPool(IERC20(address(bad)), address(escrow), RATE_BPS, CAP_BPS, "x", "y");
    }

    function test_construction_rejectsBadRate() public {
        vm.expectRevert(RecoveryPool.InvalidRate.selector);
        new RecoveryPool(IERC20(address(asset)), address(escrow), 0, CAP_BPS, "x", "y");
        vm.expectRevert(RecoveryPool.InvalidRate.selector);
        new RecoveryPool(IERC20(address(asset)), address(escrow), 10_001, CAP_BPS, "x", "y");
    }

    /// A cap below par would let the protocol repay less than it borrowed.
    function test_construction_rejectsCapBelowPar() public {
        vm.expectRevert(RecoveryPool.InvalidCap.selector);
        new RecoveryPool(IERC20(address(asset)), address(escrow), RATE_BPS, 9_999, "x", "y");
    }

    // ── Funding window ──────────────────────────────────────────────────────

    function test_deposit_mintsNotesOneToOne() public {
        _deposit(alice, 60_000_000);
        _deposit(bob, 40_000_000);
        assertEq(note.balanceOf(alice), 60_000_000);
        assertEq(note.balanceOf(bob), 40_000_000);
        assertEq(note.totalSupply(), 100_000_000);
        assertEq(asset.balanceOf(address(pool)), 100_000_000);
    }

    /// Nothing is committed while the window is open, so exit is unconditional.
    function test_withdraw_isUnconditionalWhileOpen() public {
        _deposit(alice, 60_000_000);
        vm.prank(alice);
        pool.withdraw(20_000_000);
        assertEq(note.balanceOf(alice), 40_000_000);
        assertEq(asset.balanceOf(alice), 20_000_000);
        assertEq(asset.balanceOf(address(pool)), 40_000_000);
    }

    function test_depositAndWithdraw_revertOnceClosed() public {
        _deposit(alice, 60_000_000);
        pool.close();

        asset.mint(alice, 1_000_000);
        vm.startPrank(alice);
        asset.approve(address(pool), 1_000_000);
        vm.expectRevert(RecoveryPool.AlreadyClosed.selector);
        pool.deposit(1_000_000);
        vm.expectRevert(RecoveryPool.AlreadyClosed.selector);
        pool.withdraw(1);
        vm.stopPrank();
    }

    function test_redeem_revertsBeforeClose() public {
        _deposit(alice, 60_000_000);
        _repay(10_000_000);
        vm.prank(alice);
        vm.expectRevert(RecoveryPool.NotClosed.selector);
        pool.redeem(1_000_000, alice);
    }

    // ── close() ─────────────────────────────────────────────────────────────

    /// The whole point: LP capital lands in the escrow in one transfer, so
    /// claimants are made whole immediately rather than waiting on revenue.
    function test_close_fundsEscrowAndStartsTheClock() public {
        _deposit(alice, 60_000_000);
        _deposit(bob, 40_000_000);

        pool.close();

        assertTrue(pool.closed());
        assertTrue(note.mintingClosed(), "minting must latch shut at close");
        assertEq(asset.balanceOf(address(pool)), 0, "raise must leave the pool");
        assertEq(asset.balanceOf(address(escrow)), 100_000_000, "escrow not funded");
        assertEq(pool.principal(), 100_000_000);
        assertEq(pool.debt(), 100_000_000);
        assertEq(pool.maxInterest(), 20_000_000, "cap = 0.2x principal");
        assertEq(pool.lastAccrual(), block.timestamp);
        // Obligation per note starts at exactly par.
        assertEq(pool.owedPerNote(), 1e6);

        // Claimants can be paid at par right away.
        escrow.finalize();
        assertEq(escrow.pricePerClaim(), 1e6, "claims should be whole on day one");
    }

    function test_close_onlyAdminOnceAndNotEmpty() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryPool.OnlyAdmin.selector);
        pool.close();

        vm.expectRevert(RecoveryPool.NothingRaised.selector);
        pool.close();

        _deposit(alice, 1_000_000);
        pool.close();
        vm.expectRevert(RecoveryPool.AlreadyClosed.selector);
        pool.close();
    }

    /// A short raise is allowed: it funds the escrow partially and the claims
    /// price themselves correctly on their own.
    function test_close_undersubscribedIsAllowed() public {
        _deposit(alice, 40_000_000);
        pool.close();
        escrow.finalize();
        assertEq(pool.principal(), 40_000_000);
        assertEq(escrow.pricePerClaim(), 400_000, "40% coverage");
    }

    // ── Accrual ─────────────────────────────────────────────────────────────

    function test_accrue_interestOnOutstanding() public {
        _deposit(alice, 100_000_000);
        pool.close();

        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(pool.totalOwed(), 110_000_000, "10% for one year");
        assertEq(pool.owedPerNote(), 1.1e6);

        pool.accrue();
        assertEq(pool.debt(), 110_000_000, "accrue must persist the view");
        assertEq(pool.interestAccrued(), 10_000_000);
    }

    /// The obligation is bounded however long repayment takes — the analogue of
    /// the spigot's immutable share clamp, applied to the LP side.
    function test_accrue_capsAtMaxRepayment() public {
        _deposit(alice, 100_000_000);
        pool.close();

        vm.warp(vm.getBlockTimestamp() + 3650 days); // ten years at 10%
        assertEq(pool.totalOwed(), 120_000_000, "capped at 1.2x principal");

        pool.accrue();
        assertEq(pool.debt(), 120_000_000);
        assertEq(pool.interestAccrued(), pool.maxInterest());

        // Further time adds nothing.
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        pool.accrue();
        assertEq(pool.debt(), 120_000_000, "cap must hold forever");
    }

    /// Interest runs on what is still outstanding, so repaying early is cheaper.
    function test_accrue_stopsEarningOnTheRepaidPortion() public {
        _deposit(alice, 100_000_000);
        pool.close();

        vm.warp(vm.getBlockTimestamp() + 365 days); // owed 110M
        _repay(55_000_000);
        vm.prank(alice);
        pool.redeem(50_000_000, alice); // draws 27.5M, debt -> 82.5M

        assertEq(pool.debt(), 82_500_000);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        // 10% of 82.5M, not of the original 100M.
        assertEq(pool.totalOwed(), 90_750_000);
    }

    // ── Draw-down: the obligation-neutrality property ───────────────────────

    /// Drawing a partial repayment burns only the fraction of the notes that the
    /// cash actually repaid, so the redeemer keeps a claim on the remainder and
    /// the obligation per note is unchanged for everyone.
    function test_redeem_partialDrawIsObligationNeutral() public {
        _deposit(alice, 60_000_000);
        _deposit(bob, 40_000_000);
        pool.close();

        vm.warp(vm.getBlockTimestamp() + 365 days); // owed 110M over 100M notes
        _repay(55_000_000); // half covered

        uint256 owedPerNoteBefore = pool.owedPerNote();
        assertEq(owedPerNoteBefore, 1.1e6);

        (uint256 previewAssets, uint256 previewBurn) = pool.previewRedeem(60_000_000);

        vm.prank(alice);
        (uint256 assets, uint256 burned) = pool.redeem(60_000_000, alice);

        assertEq(assets, previewAssets, "preview must match execution");
        assertEq(burned, previewBurn, "preview must match execution");
        assertEq(assets, 33_000_000, "60% of the 55M available");
        assertEq(burned, 30_000_000, "burns only the repaid half of the notes");

        assertEq(asset.balanceOf(alice), 33_000_000);
        assertEq(note.balanceOf(alice), 30_000_000, "retains a claim on the remainder");
        assertEq(pool.debt(), 77_000_000, "obligation falls 1:1 with cash paid");
        assertEq(note.totalSupply(), 70_000_000);
        assertEq(pool.owedPerNote(), owedPerNoteBefore, "obligation per note must not move");
    }

    /// Bob, who did nothing, is neither diluted nor enriched by Alice's draw.
    function test_redeem_bystanderEntitlementUnchanged() public {
        _deposit(alice, 60_000_000);
        _deposit(bob, 40_000_000);
        pool.close();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repay(55_000_000);

        uint256 bobOwedBefore = note.balanceOf(bob) * pool.owedPerNote() / pool.ONE();

        vm.prank(alice);
        pool.redeem(60_000_000, alice);

        uint256 bobOwedAfter = note.balanceOf(bob) * pool.owedPerNote() / pool.ONE();
        assertEq(bobOwedAfter, bobOwedBefore, "bystander entitlement moved");
        assertEq(bobOwedAfter, 44_000_000, "40% of 110M");
    }

    /// End to end: LPs are repaid principal + interest exactly, notes go to zero,
    /// and revenue that keeps arriving afterwards lands with the claimants.
    function test_fullRepaymentLifecycle() public {
        _deposit(alice, 60_000_000);
        _deposit(bob, 40_000_000);
        pool.close();
        uint256 escrowAfterClose = asset.balanceOf(address(escrow));

        vm.warp(vm.getBlockTimestamp() + 365 days); // owed 110M
        _repay(55_000_000);
        vm.prank(alice);
        pool.redeem(60_000_000, alice); // 33M out, 30M notes left

        _repay(77_000_000); // over-repays: cash 99M vs 77M owed

        // Read balances before pranking — an argument-position call would consume
        // the prank and redeem as the test contract.
        uint256 aliceNotes = note.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(aliceNotes, alice);
        assertEq(note.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), 66_000_000, "alice repaid 60% of 110M");

        uint256 bobNotes = note.balanceOf(bob);
        vm.prank(bob);
        pool.redeem(bobNotes, bob);
        assertEq(note.balanceOf(bob), 0);
        assertEq(asset.balanceOf(bob), 44_000_000, "bob repaid 40% of 110M");

        assertEq(note.totalSupply(), 0, "all notes discharged");
        assertEq(pool.debt(), 0, "obligation discharged");

        // The 22M over-repayment is not LP money — it belongs to the claimants.
        uint256 excess = pool.forwardExcess();
        assertEq(excess, 22_000_000);
        assertEq(asset.balanceOf(address(pool)), 0);
        assertEq(asset.balanceOf(address(escrow)), escrowAfterClose + 22_000_000);
    }

    function test_redeem_cannotDrawMoreThanOwed() public {
        _deposit(alice, 100_000_000);
        pool.close();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repay(500_000_000); // wildly over-repaid

        vm.prank(alice);
        (uint256 assets, uint256 burned) = pool.redeem(100_000_000, alice);
        assertEq(assets, 110_000_000, "capped at principal + interest");
        assertEq(burned, 100_000_000, "all notes discharged");
        assertEq(pool.debt(), 0);

        vm.prank(alice);
        vm.expectRevert(RecoveryPool.NothingToRedeem.selector);
        pool.redeem(1, alice);
    }

    // ── forwardExcess ───────────────────────────────────────────────────────

    function test_forwardExcess_onlyAboveTheObligation() public {
        _deposit(alice, 100_000_000);
        pool.close();
        uint256 escrowBefore = asset.balanceOf(address(escrow));

        _repay(50_000_000); // under-covered: nothing is excess
        vm.expectRevert(RecoveryPool.NoExcess.selector);
        pool.forwardExcess();

        vm.warp(vm.getBlockTimestamp() + 365 days); // owed 110M
        _repay(100_000_000); // cash 150M vs 110M owed
        uint256 excess = pool.forwardExcess();
        assertEq(excess, 40_000_000);
        assertEq(asset.balanceOf(address(escrow)), escrowBefore + 40_000_000);
        assertEq(asset.balanceOf(address(pool)), 110_000_000, "obligation stays behind");
    }

    function test_forwardExcess_revertsBeforeClose() public {
        _deposit(alice, 10_000_000);
        vm.expectRevert(RecoveryPool.NotClosed.selector);
        pool.forwardExcess();
    }

    /// Terminal state: with every note burned the pool is a pass-through to the
    /// claimants, so a spigot left pointing at it keeps benefiting them.
    function test_forwardExcess_passesThroughOnceDischarged() public {
        _deposit(alice, 100_000_000);
        pool.close();
        uint256 escrowBefore = asset.balanceOf(address(escrow));
        _repay(200_000_000);
        vm.prank(alice);
        pool.redeem(100_000_000, alice);
        assertEq(note.totalSupply(), 0);

        pool.forwardExcess();
        _repay(7_000_000);
        pool.forwardExcess();
        assertEq(asset.balanceOf(address(pool)), 0, "everything passes through");
        assertEq(asset.balanceOf(address(escrow)), escrowBefore + 107_000_000);
    }

    // ── Note token ──────────────────────────────────────────────────────────

    function test_note_mintBurnArePoolOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(RecoveryNote.OnlyPool.selector);
        note.mint(alice, 1);
        vm.expectRevert(RecoveryNote.OnlyPool.selector);
        note.burn(alice, 1);
        vm.expectRevert(RecoveryNote.OnlyPool.selector);
        note.closeMinting();
        vm.stopPrank();
    }

    function test_note_isFreelyTransferable() public {
        _deposit(alice, 60_000_000);
        pool.close();
        vm.prank(alice);
        note.transfer(carol, 20_000_000);
        assertEq(note.balanceOf(carol), 20_000_000);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repay(66_000_000); // covers 66M of the 66M owed

        // The buyer redeems on their own account; the pool has no idea.
        vm.prank(carol);
        (uint256 assets,) = pool.redeem(20_000_000, carol);
        assertEq(assets, 22_000_000, "1/3 of the 66M obligation");
    }

    // ── Views in the degenerate states ──────────────────────────────────────

    /// Before the raise is committed there is no obligation and nothing to draw.
    function test_views_areZeroBeforeClose() public {
        _deposit(alice, 60_000_000);
        assertEq(pool.totalOwed(), 0);
        assertEq(pool.owedPerNote(), 0);
        assertEq(pool.cashPerNote(), 0);
        (uint256 assets, uint256 burned) = pool.previewRedeem(60_000_000);
        assertEq(assets, 0);
        assertEq(burned, 0);
    }

    /// And after the last note burns, the pool is inert.
    function test_views_areZeroOnceDischarged() public {
        _deposit(alice, 100_000_000);
        pool.close();
        _repay(200_000_000);
        vm.prank(alice);
        pool.redeem(100_000_000, alice);

        assertEq(note.totalSupply(), 0);
        assertEq(pool.owedPerNote(), 0);
        assertEq(pool.cashPerNote(), 0);
        (uint256 assets, uint256 burned) = pool.previewRedeem(1);
        assertEq(assets, 0);
        assertEq(burned, 0);
    }

    function test_accrue_isNoOpBeforeCloseAndWithinTheSameBlock() public {
        pool.accrue(); // no window closed yet: nothing to accrue, must not revert
        assertEq(pool.debt(), 0);

        _deposit(alice, 100_000_000);
        pool.close();
        vm.warp(vm.getBlockTimestamp() + 365 days);

        pool.accrue();
        uint256 debtAfter = pool.debt();
        pool.accrue(); // same block: no time has passed
        assertEq(pool.debt(), debtAfter, "accrual must not compound within a block");
        assertEq(pool.interestAccrued(), 10_000_000);
    }

    /// Interest that rounds to nothing is a no-op rather than a revert.
    function test_accrue_dustIntervalIsANoOp() public {
        _deposit(alice, 1_000);
        pool.close();
        vm.warp(vm.getBlockTimestamp() + 1);
        pool.accrue();
        assertEq(pool.debt(), 1_000, "sub-unit interest must not round up");
        assertEq(pool.interestAccrued(), 0);
    }

    function test_forwardExcess_revertsWithNothingToForward() public {
        _deposit(alice, 100_000_000);
        pool.close();
        vm.expectRevert(RecoveryPool.NoExcess.selector);
        pool.forwardExcess();
    }

    // ── Note token ──────────────────────────────────────────────────────────

    function test_note_metadata() public view {
        assertEq(note.name(), "Recovery Note");
        assertEq(note.symbol(), "rnUSDC");
        assertEq(note.decimals(), 6);
    }

    /// The latch lives in the token, not just the pool, so the supply guarantee
    /// holds against the pool itself — which is what a secondary market needs.
    function test_note_latchBindsThePoolItself() public {
        _deposit(alice, 60_000_000);
        pool.close();

        vm.prank(address(pool));
        vm.expectRevert(RecoveryNote.MintingClosed.selector);
        note.mint(alice, 1);
    }

    // ── Fuzz ────────────────────────────────────────────────────────────────

    /// Obligation per note is invariant across any redemption, at any coverage
    /// level, at any point on the interest curve — up to the dust that rounding
    /// leaves with the holders who stay.
    function testFuzz_redeemIsObligationNeutral(
        uint96 aliceDep,
        uint96 bobDep,
        uint96 repaid,
        uint32 elapsed,
        uint96 draw
    ) public {
        aliceDep = uint96(bound(aliceDep, 1e6, 1e15));
        bobDep = uint96(bound(bobDep, 1e6, 1e15));
        _deposit(alice, aliceDep);
        _deposit(bob, bobDep);
        pool.close();

        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 3650 days));
        _repay(bound(repaid, 0, 2e15));

        uint256 before = pool.owedPerNote();
        uint256 amount = bound(draw, 0, aliceDep);

        vm.prank(alice);
        try pool.redeem(amount, alice) returns (uint256 assets, uint256 burned) {
            assertLe(burned, amount, "burned more notes than offered");
            assertLe(assets, pool.principal() * CAP_BPS / 10_000, "paid beyond the cap");
            if (note.totalSupply() > 0) {
                assertGe(pool.owedPerNote(), before, "obligation per note fell");
                // Dust only; never a material drift.
                assertLe(pool.owedPerNote() - before, 1, "obligation per note drifted");
            }
        } catch { }
    }

    /// Across an arbitrary repayment schedule, LPs are never paid more than
    /// principal plus capped interest.
    function testFuzz_neverOverpaysTheCap(uint96[5] memory drips, uint32[5] memory gaps) public {
        _deposit(alice, 100_000_000);
        pool.close();

        uint256 paidOut;
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 0, 730 days));
            _repay(bound(drips[i], 0, 50_000_000));
            uint256 held = note.balanceOf(alice);
            if (held == 0) break;
            vm.prank(alice);
            try pool.redeem(held, alice) returns (uint256 assets, uint256) {
                paidOut += assets;
            } catch { }
        }
        assertLe(paidOut, 120_000_000, "paid beyond principal + capped interest");
    }
}

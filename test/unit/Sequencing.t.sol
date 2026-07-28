// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryPool } from "../../src/RecoveryPool.sol";
import { RecoveryNote } from "../../src/RecoveryNote.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @dev Interleaved redeem / top-up / redeem sequences on both sides of the
///      system. The question these pin down: when funding arrives *between* two
///      redemptions, does the later redeemer get more — and what happens to the
///      earlier one?
contract SequencingTest is BaseTest {
    function test_escrow_topUpBetweenRedemptions_secondGetsMore() public {
        _deploy(100_000_000);
        _give(alice, 50_000_000);
        _give(bob, 50_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        // First redemption, pot 30% funded.
        assertEq(escrow.pricePerClaim(), 300_000, "price before");
        vm.prank(alice);
        uint256 first = escrow.redeem(50_000_000, alice);

        // Redemption is price-neutral: Alice's exit did not move the price.
        assertEq(escrow.pricePerClaim(), 300_000, "redeem must not move the price");

        // Top-up arrives.
        _fundPot(30_000_000);
        assertEq(escrow.pricePerClaim(), 900_000, "top-up must raise the price");

        // Second redemption, same number of claim tokens.
        vm.prank(bob);
        uint256 second = escrow.redeem(50_000_000, bob);

        assertEq(first, 15_000_000, "alice: 50% of a 30M pot");
        assertEq(second, 45_000_000, "bob: 50M+15M pot, and he is the only holder left");
        assertGt(second, first, "the later redeemer must do better");

        // Nothing is lost or created: every asset in went to a redeemer.
        assertEq(first + second, 60_000_000, "conservation");
        assertEq(asset.balanceOf(address(escrow)), 0);
    }

    /// The flip side of the same mechanism, stated plainly: Alice burned 100% of
    /// her claim for 30% of face, so the entire top-up accrued to Bob. Had she
    /// waited, they would have split 60M evenly at 30M each.
    function test_escrow_earlyRedeemerForfeitsLaterFunding() public {
        _deploy(100_000_000);
        _give(alice, 50_000_000);
        _give(bob, 50_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        vm.prank(alice);
        uint256 early = escrow.redeem(50_000_000, alice);
        _fundPot(30_000_000);
        vm.prank(bob);
        uint256 late = escrow.redeem(50_000_000, bob);

        assertEq(early, 15_000_000);
        assertEq(late, 45_000_000);
        // Equal claims, equal losses, 3x the recovery — decided purely by timing.
        assertEq(late, early * 3, "timing alone produced a 3x spread");
        assertEq(claim.balanceOf(alice), 0, "alice has no claim on the top-up left");
    }

    /// If the pot is fully funded before `finalize()` — the ordering the README
    /// prescribes — the spread disappears entirely and order stops mattering.
    function test_escrow_fullyFundedBeforeFinalize_orderIsIrrelevant() public {
        _deploy(100_000_000);
        _give(alice, 50_000_000);
        _give(bob, 50_000_000);
        _fundPot(60_000_000); // everything up front
        escrow.finalize();

        vm.prank(alice);
        uint256 first = escrow.redeem(50_000_000, alice);
        vm.prank(bob);
        uint256 second = escrow.redeem(50_000_000, bob);

        assertEq(first, 30_000_000);
        assertEq(second, 30_000_000);
        assertEq(first, second, "equal claims must recover equally");
    }

    /// The pool answers the same question differently: a partial draw burns only
    /// the notes the cash repaid, so drawing early forfeits nothing. Alice draws
    /// first, a repayment arrives, and she can still collect her full share of it.
    function test_pool_earlyDrawForfeitsNothing() public {
        RecoveryPool pool = new RecoveryPool(
            IERC20(address(asset)), address(0xDEAD), 1000, 12_000, "Recovery Note", "rnUSDC"
        );
        RecoveryNote note = pool.note();

        asset.mint(alice, 50_000_000);
        asset.mint(bob, 50_000_000);
        vm.startPrank(alice);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        vm.startPrank(bob);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        pool.close(); // 100M principal, no interest yet

        // First repayment covers 30% of the obligation. Alice draws her share.
        asset.mint(address(pool), 30_000_000);
        vm.prank(alice);
        (uint256 firstDraw,) = pool.redeem(50_000_000, alice);
        assertEq(firstDraw, 15_000_000, "her pro-rata slice of the 30M");
        assertEq(note.balanceOf(alice), 35_000_000, "keeps a claim on the unpaid 70%");

        // Second repayment arrives. Unlike the escrow, Alice is still entitled.
        asset.mint(address(pool), 70_000_000);
        uint256 aliceNotes = note.balanceOf(alice); // read before pranking
        vm.prank(alice);
        (uint256 secondDraw,) = pool.redeem(aliceNotes, alice);
        vm.prank(bob);
        (uint256 bobDraw,) = pool.redeem(50_000_000, bob);

        assertEq(firstDraw + secondDraw, 50_000_000, "alice recovers her full principal");
        assertEq(bobDraw, 50_000_000, "bob recovers his, and timing bought him nothing");
        assertEq(note.totalSupply(), 0);
    }

    // ── "Everyone gets their share of (paid out + balance)" ──────────────────

    /// @dev Deploy a pool and seat alice/bob at 50M each.
    function _seatedPool(uint256 rateBps) internal returns (RecoveryPool pool, RecoveryNote note) {
        pool = new RecoveryPool(
            IERC20(address(asset)), address(0xDEAD), rateBps, 20_000, "Recovery Note", "rnUSDC"
        );
        note = pool.note();
        asset.mint(alice, 50_000_000);
        asset.mint(bob, 50_000_000);
        vm.startPrank(alice);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        vm.startPrank(bob);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        pool.close();
    }

    function _draw(RecoveryPool pool, RecoveryNote note, address who) internal returns (uint256) {
        uint256 held = note.balanceOf(who); // read before pranking
        if (held == 0) return 0;
        vm.prank(who);
        try pool.redeem(held, who) returns (uint256 a, uint256) {
            return a;
        } catch {
            return 0;
        }
    }

    /// With no interest running, the rule holds exactly: however the draws and
    /// repayments interleave, each LP ends up with their original share of
    /// everything that reached the LPs.
    function test_pool_withoutInterest_eachGetsOriginalShareOfTotalPaid() public {
        (RecoveryPool pool, RecoveryNote note) = _seatedPool(1); // rate irrelevant: no time passes

        uint256 aliceTotal;
        uint256 bobTotal;

        asset.mint(address(pool), 30_000_000); // repayment 1
        aliceTotal += _draw(pool, note, alice); // only alice draws
        asset.mint(address(pool), 70_000_000); // repayment 2
        aliceTotal += _draw(pool, note, alice);
        bobTotal += _draw(pool, note, bob);

        uint256 paidToLPs = aliceTotal + bobTotal;
        assertEq(paidToLPs, 100_000_000, "the whole obligation was repaid");
        assertEq(aliceTotal, paidToLPs / 2, "alice: original 50% share");
        assertEq(bobTotal, paidToLPs / 2, "bob: original 50% share");
        assertEq(note.totalSupply(), 0);
    }

    /// Once interest is running the rule stops holding — deliberately. Alice draws
    /// before the interest accrues, which returns that capital to her early and
    /// stops it earning. Bob leaves his in and earns on the whole amount for
    /// longer, so he ends up ahead. That is what "interest on the outstanding
    /// balance" means; paying both the same would be paying Alice twice.
    function test_pool_withInterest_earlyDrawerStopsEarningOnWhatTheyDrew() public {
        (RecoveryPool pool, RecoveryNote note) = _seatedPool(1000); // 10%/yr

        uint256 aliceTotal;
        uint256 bobTotal;

        asset.mint(address(pool), 30_000_000);
        aliceTotal += _draw(pool, note, alice); // alice takes 15M out early

        vm.warp(vm.getBlockTimestamp() + 365 days); // interest runs on what is left

        asset.mint(address(pool), 200_000_000); // more than enough to finish
        aliceTotal += _draw(pool, note, alice);
        bobTotal += _draw(pool, note, bob);

        assertEq(note.totalSupply(), 0, "both fully discharged");
        assertGt(bobTotal, aliceTotal, "the LP who left capital in earns more");
        // Both recover their principal; the interest splits by capital-time, not
        // by original share.
        assertGe(aliceTotal, 50_000_000, "alice still recovers her principal");
        assertGe(bobTotal, 50_000_000, "bob still recovers his principal");
        assertEq(aliceTotal, 53_500_000, "50M principal + interest on the 35M she left in");
        assertEq(bobTotal, 55_000_000, "50M principal + interest on the full 50M");
    }

    /// The escrow does *not* satisfy the rule, and this is the gap: alice's share
    /// of everything that ever entered the pot is 30M, but redeeming early paid
    /// her 15M and burned the claim that would have collected the rest.
    function test_escrow_doesNotPayOriginalShareOfTotalInflows() public {
        _deploy(100_000_000);
        _give(alice, 50_000_000);
        _give(bob, 50_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        vm.prank(alice);
        uint256 aliceGot = escrow.redeem(50_000_000, alice);
        _fundPot(30_000_000);
        vm.prank(bob);
        uint256 bobGot = escrow.redeem(50_000_000, bob);

        uint256 totalInflows = 60_000_000;
        assertEq(aliceGot + bobGot, totalInflows, "conservation still holds in aggregate");
        // The rule would say 30M each. It is not what happens.
        assertLt(aliceGot, totalInflows / 2, "alice under her original share");
        assertGt(bobGot, totalInflows / 2, "bob over his");
    }
}

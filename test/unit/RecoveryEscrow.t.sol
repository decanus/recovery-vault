// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { ReenteringReceiver } from "../mocks/ReenteringReceiver.sol";

contract RecoveryEscrowTest is BaseTest {
    // ── Construction ────────────────────────────────────────────────────────

    function test_construction_wiring() public {
        _deploy(100_000_000);
        assertEq(address(escrow.asset()), address(asset));
        assertEq(claim.escrow(), address(escrow));
        assertEq(escrow.admin(), admin);
        assertEq(claim.decimals(), asset.decimals());
        assertEq(escrow.ONE(), 1e6);
        assertFalse(escrow.finalized());
        // Entire supply minted to the creator (this contract).
        assertEq(claim.totalSupply(), 100_000_000);
        assertEq(claim.balanceOf(admin), 100_000_000);
    }

    function test_construction_rejectsHighDecimals() public {
        MockERC20 bad = new MockERC20("Big", "BIG", 19);
        vm.expectRevert(RecoveryEscrow.DecimalsTooHigh.selector);
        new RecoveryEscrow(IERC20(address(bad)), 1, "x", "y");
    }

    function test_construction_accepts18Decimals() public {
        MockERC20 ok = new MockERC20("Eighteen", "E18", 18);
        RecoveryEscrow e = new RecoveryEscrow(IERC20(address(ok)), 1, "x", "y");
        assertEq(e.ONE(), 1e18);
    }

    // ── Claim flow: burn + transfer to claimer ──────────────────────────────

    function test_redeem_burnsClaimAndTransfersAsset() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        uint256 supplyBefore = claim.totalSupply();
        uint256 escrowBalBefore = asset.balanceOf(address(escrow));

        vm.prank(alice);
        uint256 assets = escrow.redeem(40_000_000, carol);

        // claim tokens burned from the redeemer
        assertEq(claim.balanceOf(alice), 60_000_000, "claim not burned from redeemer");
        assertEq(claim.totalSupply(), supplyBefore - 40_000_000, "supply not reduced by burn");
        // asset transferred to the named recipient
        assertEq(assets, 12_000_000, "wrong payout"); // 40% of 30M
        assertEq(asset.balanceOf(carol), 12_000_000, "asset not sent to claimer");
        assertEq(
            asset.balanceOf(address(escrow)), escrowBalBefore - 12_000_000, "escrow balance wrong"
        );
    }

    // ── Balance-backed pot: any asset in is redeemable ──────────────────────

    function test_anyAssetSentIn_isRedeemable_andRaisesPrice() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        assertEq(escrow.pricePerClaim(), 300_000);

        // A direct transfer in (no fund function exists) raises the price and is
        // redeemable — provenance does not matter, it backs the claims.
        asset.mint(address(this), 20_000_000);
        asset.transfer(address(escrow), 20_000_000);
        assertEq(escrow.pricePerClaim(), 500_000, "direct transfer must raise price");

        vm.prank(alice);
        uint256 got = escrow.redeem(100_000_000, alice);
        assertEq(got, 50_000_000, "donation must be payable");
    }

    // ── Price basis ─────────────────────────────────────────────────────────

    function test_priceBasis_concrete() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        assertEq(escrow.pricePerClaim(), 300_000, "wrong price basis");

        vm.prank(alice);
        uint256 got = escrow.redeem(50_000_000, alice);
        assertEq(got, 15_000_000, "wrong payout");

        assertEq(asset.balanceOf(address(escrow)), 15_000_000);
        assertEq(claim.totalSupply(), 50_000_000);
        assertEq(escrow.pricePerClaim(), 300_000, "redemption moved the price");
    }

    function test_priceBasis_afterSecondInflow() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        _fundPot(30_000_000);
        escrow.finalize();

        vm.prank(alice);
        escrow.redeem(50_000_000, alice); // pot 15M, supply 50M

        _fundPot(20_000_000); // pot 35M, supply 50M
        assertEq(escrow.pricePerClaim(), 700_000);

        vm.prank(alice);
        escrow.redeem(10_000_000, alice);
        assertEq(escrow.pricePerClaim(), 700_000, "inflow price not preserved on redeem");
    }

    // ── Redeem gating ───────────────────────────────────────────────────────

    function test_redeem_revertsPreFinalizationEvenIfFunded() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        _fundPot(100_000_000);
        vm.prank(alice);
        vm.expectRevert(RecoveryEscrow.NotFinalized.selector);
        escrow.redeem(1, alice);
    }

    // ── Rounding ────────────────────────────────────────────────────────────

    function test_rounding_dustHolderGetsZero() public {
        _deploy(3);
        _give(alice, 2);
        _give(bob, 1);
        _fundPot(100);
        escrow.finalize();

        uint256 priceBefore = escrow.pricePerClaim();
        vm.prank(bob);
        uint256 got = escrow.redeem(1, bob);
        assertEq(got, uint256(33), "floor payout"); // floor(100*1/3)
        assertEq(claim.totalSupply(), 2);
        assertGe(escrow.pricePerClaim(), priceBefore, "price decreased on dust redeem");
    }

    function test_rounding_manySmallRedemptionsNeverDecreasePrice() public {
        _deploy(1_000_000_000_000);
        _give(alice, 1_000_000_000_000);
        _fundPot(333_333_333_333); // non-divisible
        escrow.finalize();

        uint256 last = escrow.pricePerClaim();
        for (uint256 i; i < 10_000; ++i) {
            vm.prank(alice);
            escrow.redeem(1, alice);
            uint256 p = escrow.pricePerClaim();
            assertGe(p, last, "price decreased under sequential 1-wei redemptions");
            last = p;
        }
    }

    function test_rounding_lastHolderDrainsNoDivByZero() public {
        _deploy(7);
        _give(alice, 7);
        _fundPot(1000);
        escrow.finalize();

        vm.prank(alice);
        uint256 got = escrow.redeem(7, alice);
        assertEq(got, 1000, "full supply redemption pays whole pot");
        assertEq(claim.totalSupply(), 0);
        assertEq(asset.balanceOf(address(escrow)), 0);
        assertEq(escrow.pricePerClaim(), 0, "supply==0 prices at 0, no revert");
    }

    // ── Other people's redemptions ──────────────────────────────────────────

    function test_othersRedemption_claimableNonDecreasing_fullExit() public {
        _deploy(100_000_000);
        _give(alice, 50_000_000);
        _give(bob, 30_000_000);
        _give(carol, 20_000_000);
        _fundPot(40_000_000);
        escrow.finalize();

        uint256 bBal = claim.balanceOf(bob);
        uint256 cBal = claim.balanceOf(carol);
        uint256 bClaim = bBal * escrow.pricePerClaim() / escrow.ONE();
        uint256 cClaim = cBal * escrow.pricePerClaim() / escrow.ONE();

        vm.prank(alice);
        escrow.redeem(50_000_000, alice);

        assertEq(claim.balanceOf(bob), bBal, "B balance changed");
        assertEq(claim.balanceOf(carol), cBal, "C balance changed");
        assertGe(bBal * escrow.pricePerClaim() / escrow.ONE(), bClaim);
        assertGe(cBal * escrow.pricePerClaim() / escrow.ONE(), cClaim);
    }

    function test_othersRedemption_dustConcentration() public {
        // pot 1000, supply 7, holders at 6 and 1.
        _deploy(7);
        _give(alice, 6);
        _give(bob, 1);
        _fundPot(1000);
        escrow.finalize();

        uint256 rawBefore = asset.balanceOf(address(escrow)) / claim.totalSupply(); // 142
        assertEq(rawBefore, 142);

        vm.prank(alice);
        escrow.redeem(6, alice); // pays floor(6*1000/7)=857, pot->143, supply->1

        uint256 rawAfter = asset.balanceOf(address(escrow)) / claim.totalSupply(); // 143/1
        assertEq(rawAfter, 143);
        assertGe(rawAfter, rawBefore);
    }

    // ── Adversarial ─────────────────────────────────────────────────────────

    function test_reentrancy_cannotDoubleRedeem() public {
        _deploy(100_000_000);
        ReenteringReceiver rr = new ReenteringReceiver(escrow);
        _give(address(rr), 100_000_000);
        _fundPot(100_000_000);
        escrow.finalize();

        rr.redeem(40_000_000);
        assertEq(asset.balanceOf(address(rr)), 40_000_000);
        assertEq(claim.balanceOf(address(rr)), 60_000_000);
    }

    // ── Access control ──────────────────────────────────────────────────────

    function test_finalize_onlyAdmin() public {
        _deploy(100_000_000);
        vm.prank(alice);
        vm.expectRevert(RecoveryEscrow.OnlyAdmin.selector);
        escrow.finalize();
    }

    function test_finalize_twiceReverts() public {
        _deploy(100_000_000);
        escrow.finalize();
        vm.expectRevert(RecoveryEscrow.AlreadyFinalized.selector);
        escrow.finalize();
    }

    // ── Conservation spot-check ─────────────────────────────────────────────

    function test_conservation_holdsAcrossMixedOps() public {
        _deploy(100_000_000);
        _give(alice, 100_000_000);
        uint256 inflows = 40_000_000;
        _fundPot(40_000_000);
        asset.mint(address(this), 10_000_000);
        asset.transfer(address(escrow), 10_000_000); // any transfer counts
        inflows += 10_000_000;
        escrow.finalize();

        vm.prank(alice);
        uint256 paid = escrow.redeem(30_000_000, alice);

        assertEq(inflows, paid + asset.balanceOf(address(escrow)), "I3 conservation broken");
    }
}

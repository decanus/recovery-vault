// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";

contract DistributionTest is BaseTest {
    function _batch(address[] memory tos, uint256[] memory amts) internal {
        escrow.distribute(tos, amts);
    }

    function test_threeBatches_supplyIsSum_duplicatesAccumulate() public {
        address[] memory t1 = new address[](2);
        uint256[] memory a1 = new uint256[](2);
        t1[0] = alice;
        t1[1] = bob;
        a1[0] = 10;
        a1[1] = 20;
        _batch(t1, a1);

        address[] memory t2 = new address[](1);
        uint256[] memory a2 = new uint256[](1);
        t2[0] = carol;
        a2[0] = 30;
        _batch(t2, a2);

        // third batch repeats alice -> should accumulate, not overwrite
        address[] memory t3 = new address[](1);
        uint256[] memory a3 = new uint256[](1);
        t3[0] = alice;
        a3[0] = 5;
        _batch(t3, a3);

        assertEq(claim.balanceOf(alice), 15, "duplicate did not accumulate");
        assertEq(claim.balanceOf(bob), 20);
        assertEq(claim.balanceOf(carol), 30);
        assertEq(claim.totalSupply(), 65, "supply != sum of batches");
    }

    function test_correct_movesAllocationWithoutChangingSupply() public {
        _distribute(alice, 100);
        uint256 supplyBefore = claim.totalSupply();
        escrow.correct(alice, bob, 40);
        assertEq(claim.balanceOf(alice), 60);
        assertEq(claim.balanceOf(bob), 40);
        assertEq(claim.totalSupply(), supplyBefore, "correct changed total supply");
    }

    function test_distribute_lengthMismatchReverts() public {
        address[] memory tos = new address[](2);
        uint256[] memory amts = new uint256[](1);
        tos[0] = alice;
        tos[1] = bob;
        amts[0] = 1;
        vm.expectRevert(RecoveryEscrow.LengthMismatch.selector);
        escrow.distribute(tos, amts);
    }

    function test_finalize_twiceReverts() public {
        escrow.finalize();
        vm.expectRevert(RecoveryEscrow.AlreadyFinalized.selector);
        escrow.finalize();
    }

    function test_distributeCorrectRevertPostFinalization() public {
        _distribute(alice, 100);
        escrow.finalize();

        address[] memory tos = new address[](1);
        uint256[] memory amts = new uint256[](1);
        tos[0] = bob;
        amts[0] = 1;
        vm.expectRevert(RecoveryEscrow.AlreadyFinalized.selector);
        escrow.distribute(tos, amts);

        vm.expectRevert(RecoveryEscrow.AlreadyFinalized.selector);
        escrow.correct(alice, bob, 1);
    }

    function test_mint_revertsPostFinalization_viaClaimDirectly() public {
        escrow.finalize();
        vm.prank(address(escrow));
        vm.expectRevert(RecoveryClaim.MintingClosed.selector);
        claim.mint(alice, 1);
    }

    function test_distribute_emptyBatchIsNoop() public {
        address[] memory tos = new address[](0);
        uint256[] memory amts = new uint256[](0);
        escrow.distribute(tos, amts); // loop body never runs
        assertEq(claim.totalSupply(), 0);
    }

    function test_finalize_flipsFlagsAndClosesMinting() public {
        assertFalse(escrow.finalized());
        assertFalse(claim.mintingClosed());
        escrow.finalize();
        assertTrue(escrow.finalized());
        assertTrue(claim.mintingClosed());
    }
}

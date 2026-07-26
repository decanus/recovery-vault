// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

contract RecoveryClaimTest is BaseTest {
    // ── Metadata / wiring ────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(claim.name(), "Recovery Claim");
        assertEq(claim.symbol(), "rcUSDC");
        assertEq(claim.decimals(), 6);
        assertEq(claim.escrow(), address(escrow));
        assertFalse(claim.mintingClosed());
    }

    // ── Mint/burn access control ─────────────────────────────────────────────

    function test_mint_onlyEscrow() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryClaim.OnlyEscrow.selector);
        claim.mint(alice, 1);
    }

    function test_burn_onlyEscrow() public {
        _distribute(alice, 100);
        vm.prank(alice);
        vm.expectRevert(RecoveryClaim.OnlyEscrow.selector);
        claim.burn(alice, 1);
    }

    function test_closeMinting_onlyEscrow() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryClaim.OnlyEscrow.selector);
        claim.closeMinting();
    }

    function test_mint_revertsAfterClose() public {
        escrow.finalize(); // calls closeMinting
        assertTrue(claim.mintingClosed());
        // even the escrow itself cannot mint now
        vm.prank(address(escrow));
        vm.expectRevert(RecoveryClaim.MintingClosed.selector);
        claim.mint(alice, 1);
    }

    function test_burn_stillWorksAfterClose() public {
        _distribute(alice, 100);
        escrow.finalize();
        vm.prank(address(escrow));
        claim.burn(alice, 40);
        assertEq(claim.balanceOf(alice), 60);
    }

    // ── ERC-20 conformance ───────────────────────────────────────────────────

    function test_transfer() public {
        _distribute(alice, 100);
        vm.prank(alice);
        claim.transfer(bob, 40);
        assertEq(claim.balanceOf(alice), 60);
        assertEq(claim.balanceOf(bob), 40);
    }

    function test_selfTransfer() public {
        _distribute(alice, 100);
        vm.prank(alice);
        claim.transfer(alice, 40);
        assertEq(claim.balanceOf(alice), 100);
    }

    function test_approveAndTransferFrom() public {
        _distribute(alice, 100);
        vm.prank(alice);
        claim.approve(bob, 30);
        assertEq(claim.allowance(alice, bob), 30);
        vm.prank(bob);
        claim.transferFrom(alice, carol, 30);
        assertEq(claim.balanceOf(carol), 30);
        assertEq(claim.allowance(alice, bob), 0);
    }

    function test_transferFrom_insufficientAllowanceReverts() public {
        _distribute(alice, 100);
        vm.prank(alice);
        claim.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        claim.transferFrom(alice, carol, 11);
    }

    function test_transfer_insufficientBalanceReverts() public {
        _distribute(alice, 100);
        vm.prank(alice);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        claim.transfer(bob, 101);
    }

    function test_infiniteAllowanceNotDecremented() public {
        _distribute(alice, 100);
        vm.prank(alice);
        claim.approve(bob, type(uint256).max);
        vm.prank(bob);
        claim.transferFrom(alice, carol, 30);
        assertEq(claim.allowance(alice, bob), type(uint256).max);
    }

    function test_totalSupplyTracksMintBurn() public {
        _distribute(alice, 100);
        _distribute(bob, 50);
        assertEq(claim.totalSupply(), 150);
        _fund(admin, 150);
        escrow.finalize();
        vm.prank(alice);
        escrow.redeem(100, alice);
        assertEq(claim.totalSupply(), 50);
    }
}

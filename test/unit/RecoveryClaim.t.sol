// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

contract RecoveryClaimTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _deploy(1000);
    }

    // ── Metadata / wiring ────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(claim.name(), "Recovery Claim");
        assertEq(claim.symbol(), "rcUSDC");
        assertEq(claim.decimals(), 6);
        assertEq(claim.escrow(), address(escrow));
    }

    function test_fullSupplyMintedToCreator() public view {
        assertEq(claim.totalSupply(), 1000);
        assertEq(claim.balanceOf(admin), 1000);
    }

    // ── Burn access control ──────────────────────────────────────────────────

    function test_burn_onlyEscrow() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryClaim.OnlyEscrow.selector);
        claim.burn(admin, 1);
    }

    function test_burn_viaEscrow() public {
        _give(alice, 100);
        _fundPot(1000);
        escrow.finalize();
        vm.prank(alice);
        escrow.redeem(40, alice);
        assertEq(claim.balanceOf(alice), 60);
        assertEq(claim.totalSupply(), 960); // 1000 minted, 40 burned
    }

    // ── No mint exists: supply is immutable from birth ───────────────────────

    function test_noMintFunction_supplyFixed() public {
        // There is no `mint` selector; supply only ever decreases.
        (bool ok,) = address(claim).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok, "claim must not expose mint");
        assertEq(claim.totalSupply(), 1000);
    }

    // ── ERC-20 conformance ───────────────────────────────────────────────────

    function test_transfer() public {
        _give(alice, 100);
        vm.prank(alice);
        claim.transfer(bob, 40);
        assertEq(claim.balanceOf(alice), 60);
        assertEq(claim.balanceOf(bob), 40);
    }

    function test_selfTransfer() public {
        _give(alice, 100);
        vm.prank(alice);
        claim.transfer(alice, 40);
        assertEq(claim.balanceOf(alice), 100);
    }

    function test_approveAndTransferFrom() public {
        _give(alice, 100);
        vm.prank(alice);
        claim.approve(bob, 30);
        assertEq(claim.allowance(alice, bob), 30);
        vm.prank(bob);
        claim.transferFrom(alice, carol, 30);
        assertEq(claim.balanceOf(carol), 30);
        assertEq(claim.allowance(alice, bob), 0);
    }

    function test_transferFrom_insufficientAllowanceReverts() public {
        _give(alice, 100);
        vm.prank(alice);
        claim.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        claim.transferFrom(alice, carol, 11);
    }

    function test_transfer_insufficientBalanceReverts() public {
        _give(alice, 100);
        vm.prank(alice);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        claim.transfer(bob, 101);
    }

    function test_infiniteAllowanceNotDecremented() public {
        _give(alice, 100);
        vm.prank(alice);
        claim.approve(bob, type(uint256).max);
        vm.prank(bob);
        claim.transferFrom(alice, carol, 30);
        assertEq(claim.allowance(alice, bob), type(uint256).max);
    }
}

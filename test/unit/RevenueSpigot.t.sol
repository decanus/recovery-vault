// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RevenueSpigot } from "../../src/RevenueSpigot.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IRecoveryEscrow } from "../../src/interfaces/IRecoveryEscrow.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockRevenueSource } from "../mocks/MockRevenueSource.sol";

contract RevenueSpigotTest is Test {
    MockERC20 internal asset;
    RecoveryEscrow internal escrow;
    RevenueSpigot internal spigot;
    MockRevenueSource internal source;

    address internal admin = address(this);
    address internal stranger = address(0xBEEF);

    uint256 internal constant MIN = 500; // 5%
    uint256 internal constant MAX = 5000; // 50%
    uint256 internal constant INIT = 1000; // 10%

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        escrow = new RecoveryEscrow(IERC20(address(asset)), "Recovery Claim", "rcUSDC");
        spigot = new RevenueSpigot(
            IERC20(address(asset)), IRecoveryEscrow(address(escrow)), MIN, MAX, INIT
        );
        source = new MockRevenueSource(IERC20(address(asset)));
    }

    // ── Construction bounds ──────────────────────────────────────────────────

    function test_construction_badBoundsRevert() public {
        vm.expectRevert(RevenueSpigot.InvalidBounds.selector);
        new RevenueSpigot(
            IERC20(address(asset)), IRecoveryEscrow(address(escrow)), 6000, 5000, 5500
        );
    }

    function test_construction_initOutOfRangeReverts() public {
        vm.expectRevert(RevenueSpigot.ShareOutOfRange.selector);
        new RevenueSpigot(IERC20(address(asset)), IRecoveryEscrow(address(escrow)), MIN, MAX, 100);
    }

    // ── Registration ─────────────────────────────────────────────────────────

    function test_register_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(RevenueSpigot.OnlyAdmin.selector);
        spigot.register(address(source));
    }

    function test_register_cannotDuplicate() public {
        spigot.register(address(source));
        vm.expectRevert(RevenueSpigot.AlreadyRegistered.selector);
        spigot.register(address(source));
    }

    function test_register_isAppendOnly_noRemoveExists() public {
        spigot.register(address(source));
        assertTrue(spigot.registered(address(source)));
        // There is deliberately no remove/deregister function in the ABI.
    }

    // ── Routing ──────────────────────────────────────────────────────────────

    function test_route_unregisteredReverts() public {
        vm.expectRevert(RevenueSpigot.NotRegistered.selector);
        spigot.route(address(source));
    }

    function test_route_interceptsShareAndFundsEscrow() public {
        spigot.register(address(source));
        asset.mint(address(source), 1_000_000);
        source.approveSpigot(address(spigot), type(uint256).max);

        uint256 routed = spigot.route(address(source));
        // 10% of 1,000,000
        assertEq(routed, 100_000);
        assertEq(escrow.poolBalance(), 100_000, "escrow not funded");
        assertEq(asset.balanceOf(address(source)), 900_000, "remainder not left at source");
        assertEq(escrow.totalInflows(), 100_000);
    }

    function test_route_permissionless() public {
        spigot.register(address(source));
        asset.mint(address(source), 1_000_000);
        source.approveSpigot(address(spigot), type(uint256).max);
        vm.prank(stranger);
        spigot.route(address(source));
        assertEq(escrow.poolBalance(), 100_000);
    }

    function test_route_zeroShareReverts() public {
        spigot.register(address(source));
        // balance 5 -> 10% floors to 0
        asset.mint(address(source), 5);
        source.approveSpigot(address(spigot), type(uint256).max);
        vm.expectRevert(RevenueSpigot.NothingToRoute.selector);
        spigot.route(address(source));
    }

    // ── Share timelock ───────────────────────────────────────────────────────

    function test_queueShareChange_belowMinReverts() public {
        vm.expectRevert(RevenueSpigot.ShareOutOfRange.selector);
        spigot.queueShareChange(MIN - 1);
    }

    function test_queueShareChange_aboveMaxReverts() public {
        vm.expectRevert(RevenueSpigot.ShareOutOfRange.selector);
        spigot.queueShareChange(MAX + 1);
    }

    function test_shareChange_cannotExecuteBeforeTimelock() public {
        spigot.queueShareChange(2000);
        vm.expectRevert(RevenueSpigot.TimelockNotElapsed.selector);
        spigot.executeShareChange();
    }

    function test_shareChange_executesAfterTimelock() public {
        spigot.queueShareChange(2000);
        assertEq(spigot.queuedShareBps(), 2000, "queued value not public");
        assertTrue(spigot.changePending());
        vm.warp(block.timestamp + spigot.SHARE_TIMELOCK());
        spigot.executeShareChange();
        assertEq(spigot.shareBps(), 2000);
        assertFalse(spigot.changePending());
    }

    function test_shareChange_executeWithoutQueueReverts() public {
        vm.expectRevert(RevenueSpigot.NoChangePending.selector);
        spigot.executeShareChange();
    }

    function test_shareBps_cannotBeZeroedEvenAfterTimelock() public {
        // Even the admin cannot drive the share below MIN_SHARE_BPS.
        vm.expectRevert(RevenueSpigot.ShareOutOfRange.selector);
        spigot.queueShareChange(0);
    }

    function test_queueShareChange_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(RevenueSpigot.OnlyAdmin.selector);
        spigot.queueShareChange(2000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev Shared setup: a 6-decimal asset, an escrow, and its claim token, with a
///      funded admin and a couple of helper actors.
abstract contract BaseTest is Test {
    MockERC20 internal asset;
    RecoveryEscrow internal escrow;
    RecoveryClaim internal claim;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);

    uint256 internal constant ONE_6 = 1e6;

    function setUp() public virtual {
        asset = new MockERC20("USD Coin", "USDC", 6);
        escrow = new RecoveryEscrow(IERC20(address(asset)), "Recovery Claim", "rcUSDC");
        claim = escrow.claim();
    }

    /// @dev Mint `amount` asset to `who` and `fund` it into the pot as `who`.
    function _fund(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
    }

    /// @dev Mint a claim allocation to a single holder (pre-finalisation).
    function _distribute(address to, uint256 amount) internal {
        address[] memory tos = new address[](1);
        uint256[] memory amts = new uint256[](1);
        tos[0] = to;
        amts[0] = amount;
        escrow.distribute(tos, amts);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev Shared setup: a 6-decimal asset plus helpers to deploy an escrow (whose
///      full supply is minted to `admin`, i.e. this test contract), hand claim
///      tokens to holders, and fund the pot by transferring asset in.
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
    }

    /// @dev Deploy an escrow with `supply` claim tokens minted to `admin` (this).
    function _deploy(uint256 supply) internal {
        escrow = new RecoveryEscrow(IERC20(address(asset)), supply, "Recovery Claim", "rcUSDC");
        claim = escrow.claim();
    }

    /// @dev Fund the pot: any asset landing at the escrow backs the claims.
    function _fundPot(uint256 amount) internal {
        asset.mint(address(escrow), amount);
    }

    /// @dev Hand `amount` claim tokens to `to` from the creator's balance.
    function _give(address to, uint256 amount) internal {
        claim.transfer(to, amount);
    }
}

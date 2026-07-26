// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { RecoveryPool } from "../src/RecoveryPool.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @notice Deploys the optional LP pool, which deploys its bound note token. The
///         escrow must already exist (`Deploy.s.sol`) — the pool takes it as an
///         immutable beneficiary and nothing on the escrow side changes.
/// @dev    Env:
///           ASSET             — pot/revenue asset (decimals() <= 18, non-rebasing)
///           ESCROW            — the RecoveryEscrow that receives the raise
///           RATE_BPS          — annual rate on the outstanding obligation (0 < r <= 10000)
///           MAX_REPAYMENT_BPS — ceiling on total repayment, bps of principal (>= 10000)
///           NOTE_NAME         — note token name
///           NOTE_SYMBOL       — note token symbol
///         The deployer (broadcast key) becomes the pool `admin`, the only key
///         that can call `close()`.
///
///         After deploying: LPs `deposit` during the window, then `close()` ships
///         the entire raise to the escrow in one transfer and starts interest.
///         Only then should the escrow be `finalize()`d, so claimants redeem
///         against a funded pot. Repayment is a plain transfer to the pool.
contract DeployPool is Script {
    function run() external returns (RecoveryPool pool) {
        address asset = vm.envAddress("ASSET");
        address escrow = vm.envAddress("ESCROW");
        uint256 rateBps = vm.envUint("RATE_BPS");
        uint256 maxRepaymentBps = vm.envUint("MAX_REPAYMENT_BPS");
        string memory name = vm.envString("NOTE_NAME");
        string memory symbol = vm.envString("NOTE_SYMBOL");

        vm.startBroadcast();
        pool = new RecoveryPool(IERC20(asset), escrow, rateBps, maxRepaymentBps, name, symbol);
        vm.stopBroadcast();

        console.log("RecoveryPool  :", address(pool));
        console.log("RecoveryNote  :", address(pool.note()));
        console.log("escrow        :", pool.escrow());
        console.log("admin         :", pool.admin());
        console.log("rate bps      :", rateBps);
        console.log("max repay bps :", maxRepaymentBps);
    }
}

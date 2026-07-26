// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { RecoveryEscrow } from "../src/RecoveryEscrow.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @notice Deploys the escrow, which in turn deploys its bound claim token.
/// @dev    Env:
///           ASSET        — address of the pot asset (decimals() <= 18, non-rebasing)
///           CLAIM_NAME   — claim token name
///           CLAIM_SYMBOL — claim token symbol
///         The deployer (broadcast key) becomes the escrow `admin`.
contract Deploy is Script {
    function run() external returns (RecoveryEscrow escrow) {
        address asset = vm.envAddress("ASSET");
        string memory name = vm.envString("CLAIM_NAME");
        string memory symbol = vm.envString("CLAIM_SYMBOL");

        vm.startBroadcast();
        escrow = new RecoveryEscrow(IERC20(asset), name, symbol);
        vm.stopBroadcast();

        console.log("RecoveryEscrow:", address(escrow));
        console.log("RecoveryClaim :", address(escrow.claim()));
        console.log("admin         :", escrow.admin());
    }
}

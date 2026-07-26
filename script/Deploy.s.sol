// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { RecoveryEscrow } from "../src/RecoveryEscrow.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @notice Deploys the escrow, which deploys its bound claim token and mints the
///         entire supply to the deployer (the creator/admin), who then
///         distributes it off-chain (e.g. via a merkle drop).
/// @dev    Env:
///           ASSET        — address of the pot asset (decimals() <= 18, non-rebasing)
///           SUPPLY       — total claim supply to mint to the creator (raw units)
///           CLAIM_NAME   — claim token name
///           CLAIM_SYMBOL — claim token symbol
///         The deployer (broadcast key) becomes the escrow `admin` and receives
///         the full supply.
contract Deploy is Script {
    function run() external returns (RecoveryEscrow escrow) {
        address asset = vm.envAddress("ASSET");
        uint256 supply = vm.envUint("SUPPLY");
        string memory name = vm.envString("CLAIM_NAME");
        string memory symbol = vm.envString("CLAIM_SYMBOL");

        vm.startBroadcast();
        escrow = new RecoveryEscrow(IERC20(asset), supply, name, symbol);
        vm.stopBroadcast();

        console.log("RecoveryEscrow:", address(escrow));
        console.log("RecoveryClaim :", address(escrow.claim()));
        console.log("admin         :", escrow.admin());
        console.log("supply minted :", supply);
    }
}

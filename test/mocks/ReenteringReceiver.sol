// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";

/// @dev Attempts to re-enter `redeem` when it receives the asset payout. Only
///      meaningful against an asset that calls back on transfer; with a plain
///      ERC-20 the callback never fires, so this doubles as a holder that simply
///      cannot mount the attack. The `nonReentrant` guard makes the attack
///      unreachable regardless.
contract ReenteringReceiver {
    RecoveryEscrow public immutable escrow;
    bool public attacked;

    constructor(RecoveryEscrow _escrow) {
        escrow = _escrow;
    }

    function redeem(uint256 amount) external {
        escrow.redeem(amount, address(this));
    }

    /// @dev ERC-777-style hook name; a callback asset would invoke this.
    function tokensReceived(address, address, uint256) external {
        if (!attacked) {
            attacked = true;
            escrow.redeem(1, address(this));
        }
    }

    // Fallback path for assets that call an arbitrary function on receipt.
    fallback() external {
        if (!attacked) {
            attacked = true;
            try escrow.redeem(1, address(this)) { } catch { }
        }
    }
}

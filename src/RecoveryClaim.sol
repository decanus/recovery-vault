// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @title RecoveryClaim
/// @notice A vanilla, fully transferable ERC-20 representing a pro-rata claim on
///         the assets held by a `RecoveryEscrow`. The entire supply is minted
///         once, at construction, to a single recipient (the escrow creator),
///         who then distributes it however they choose — e.g. by funding a
///         merkle-drop distributor that `transfer`s tokens to claimants.
/// @dev    There is no `mint` function: supply is fixed from birth and can only
///         ever decrease, via `burn`, which the escrow calls on redemption. No
///         hooks, no transfer restrictions, no blocklist, no pause, no rebasing.
///         `transfer` and `approve` behave exactly as an integrator expects.
contract RecoveryClaim is ERC20 {
    /// @dev The sole address permitted to burn (the escrow, on redemption).
    address public immutable escrow;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    error OnlyEscrow();

    /// @param escrow_ The escrow that may burn on redemption (the deployer).
    /// @param recipient_ Receives the entire initial supply (the escrow creator).
    /// @param supply_ The total, fixed supply — the full liability.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals; the escrow sets this to `asset.decimals()`.
    constructor(
        address escrow_,
        address recipient_,
        uint256 supply_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        escrow = escrow_;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _mint(recipient_, supply_);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Burn `amount` claim tokens from `from`. Escrow-only; called on
    ///         redemption. This is the only way supply ever changes after birth.
    function burn(address from, uint256 amount) external {
        if (msg.sender != escrow) revert OnlyEscrow();
        _burn(from, amount);
    }
}

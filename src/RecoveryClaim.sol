// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @title RecoveryClaim
/// @notice A vanilla, fully transferable ERC-20 that represents a pro-rata claim
///         on the assets held by a `RecoveryEscrow`. Only the escrow may mint or
///         burn. Minting latches shut, one-way, when the escrow finalises.
/// @dev    No hooks, no transfer restrictions, no blocklist, no pause, no
///         rebasing. `transfer` and `approve` behave exactly as an integrator
///         expects. The escrow binding is immutable and set by the escrow itself
///         during its own construction, so the pairing is 1:1 and atomic.
contract RecoveryClaim is ERC20 {
    /// @dev The sole address permitted to mint and burn. Set to the deployer,
    ///      which is always the escrow (see `RecoveryEscrow` constructor).
    address public immutable escrow;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /// @notice One-way latch. Once true, no further mint is ever possible.
    /// @dev    A latch rather than a per-mint cross-contract read of the escrow's
    ///         `finalized` flag — the latter would put an external call on every
    ///         mint in a batch distribution, the gas-heaviest path in the system.
    bool public mintingClosed;

    error OnlyEscrow();
    error MintingClosed();

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert OnlyEscrow();
        _;
    }

    /// @param escrow_ The escrow that owns mint/burn rights (the deployer).
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals; the escrow sets this to `asset.decimals()`.
    constructor(address escrow_, string memory name_, string memory symbol_, uint8 decimals_) {
        escrow = escrow_;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
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

    /// @notice Mint `amount` claim tokens to `to`. Escrow-only. Reverts once
    ///         minting has been closed by `closeMinting`.
    function mint(address to, uint256 amount) external onlyEscrow {
        if (mintingClosed) revert MintingClosed();
        _mint(to, amount);
    }

    /// @notice Burn `amount` claim tokens from `from`. Escrow-only. Stays
    ///         available after minting closes — redemption is the entire point.
    function burn(address from, uint256 amount) external onlyEscrow {
        _burn(from, amount);
    }

    /// @notice Latch minting shut, permanently. Escrow-only, one-way.
    function closeMinting() external onlyEscrow {
        mintingClosed = true;
    }
}

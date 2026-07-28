// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @title RecoveryNote
/// @notice A vanilla, fully transferable ERC-20 representing a pro-rata claim on
///         the obligation owed by a `RecoveryPool` to the LPs who funded a
///         recovery. Unlike `RecoveryClaim`, supply is not fixed at birth: notes
///         are minted 1:1 against deposits during the pool's funding window, and
///         minting is latched shut, one-way, when the pool closes.
/// @dev    After `closeMinting()` supply can only ever decrease, via `burn`,
///         which the pool calls as repayments are drawn down. The latch lives in
///         the token — not just in the pool — so a holder or a secondary market
///         can verify the supply guarantee from the token alone. No hooks, no
///         transfer restrictions, no blocklist, no pause, no rebasing.
contract RecoveryNote is ERC20 {
    /// @dev The sole address permitted to mint, burn and latch (the pool).
    address public immutable pool;

    /// @notice One-way latch. Once true, `mint` reverts forever and supply is
    ///         non-increasing.
    bool public mintingClosed;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    error OnlyPool();
    error MintingClosed();

    /// @param pool_ The pool that may mint, burn and latch (the deployer).
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals; the pool sets this to `asset.decimals()`.
    constructor(address pool_, string memory name_, string memory symbol_, uint8 decimals_) {
        pool = pool_;
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

    /// @notice Mint `amount` notes to `to`. Pool-only, and only while the funding
    ///         window is open.
    function mint(address to, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        if (mintingClosed) revert MintingClosed();
        _mint(to, amount);
    }

    /// @notice Burn `amount` notes from `from`. Pool-only; called on withdrawal
    ///         during the window and on redemption after it.
    function burn(address from, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        _burn(from, amount);
    }

    /// @notice Latch minting shut, permanently. Pool-only; called from `close()`.
    function closeMinting() external {
        if (msg.sender != pool) revert OnlyPool();
        mintingClosed = true;
    }
}

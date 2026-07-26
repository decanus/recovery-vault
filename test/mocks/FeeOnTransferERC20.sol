// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @dev ERC-20 that burns a fee on every transfer, so the recipient receives
///      less than the sent amount. Used to prove `fund()` rejects it.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;
    uint8 private immutable _decimals;

    constructor(uint8 decimals_, uint256 feeBps_) {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function name() public pure override returns (string memory) {
        return "FeeOnTransfer";
    }

    function symbol() public pure override returns (string memory) {
        return "FEE";
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // Apply fee only on genuine transfers (not mint/burn), by burning part
        // of what was just delivered to `to`.
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            if (fee != 0) _burn(to, fee);
        }
    }
}

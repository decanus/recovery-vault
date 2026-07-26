// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @dev A protocol revenue source: holds asset and approves a spigot to pull its
///      intercepted share. `approveSpigot` is called once at setup.
contract MockRevenueSource {
    IERC20 public immutable asset;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function approveSpigot(address spigot, uint256 amount) external {
        asset.approve(spigot, amount);
    }
}

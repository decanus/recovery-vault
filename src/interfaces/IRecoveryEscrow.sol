// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The escrow surface the spigot relies on: the asset it funds in, and
///      the permissionless pull-funding entrypoint.
interface IRecoveryEscrow {
    function asset() external view returns (address);
    function fund(uint256 amount) external;
}

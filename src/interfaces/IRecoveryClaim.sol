// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The claim token surface the escrow relies on. The token is otherwise a
///      vanilla ERC-20; supply is fixed at construction and only `burn` (called
///      by the escrow on redemption) ever changes it.
interface IRecoveryClaim {
    function escrow() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);

    function burn(address from, uint256 amount) external;
}

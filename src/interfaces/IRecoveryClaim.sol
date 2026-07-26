// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The claim token surface the escrow relies on. The token is otherwise a
///      vanilla ERC-20; only these members are escrow-facing.
interface IRecoveryClaim {
    function escrow() external view returns (address);
    function mintingClosed() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);

    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function closeMinting() external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { RecoveryClaim } from "./RecoveryClaim.sol";

/// @title RecoveryEscrow
/// @notice Holds a pot of a single asset and owns the only burn right over a
///         `RecoveryClaim` token that represents a pro-rata claim on that pot.
///         The full claim supply is minted once, at construction, to the creator,
///         who distributes it off-chain (e.g. via a merkle drop). After
///         finalisation the only holder action is `redeem`: burn `amount` of the
///         claim token, receive `amount * balance / totalSupply` of the asset.
/// @dev    The pot is simply `asset.balanceOf(address(this))` — any asset sent to
///         this address, however it arrives, backs the claims and is redeemable.
///         There is no credited/uncredited split and no sweep: a transfer in is
///         irreversibly claimant money. This is safe here because supply is fixed
///         (nobody deposits for shares, so no inflation attack) and a donation
///         only ever raises the price pro-rata for every holder — a gift, not an
///         attack.
///
///         Trust note: because 100% of the supply is minted to the creator at
///         construction, redemption MUST NOT open until the creator has handed
///         the tokens to their distributor/claimants. `finalize()` is that gate.
contract RecoveryEscrow is ReentrancyGuard {
    using SafeTransferLib for address;

    IERC20 public immutable asset;
    RecoveryClaim public immutable claim;
    address public immutable admin;

    /// @dev One whole claim token == one whole asset unit == 10**decimals, since
    ///      `claim.decimals() == asset.decimals()`. Fixes the price fixed-point.
    uint256 public immutable ONE;

    bool public finalized;

    event Finalized();
    event Redeemed(address indexed holder, uint256 amount, uint256 assets);

    error OnlyAdmin();
    error NotFinalized();
    error AlreadyFinalized();
    error DecimalsTooHigh();

    /// @param _asset The single pot asset. Must have `decimals() <= 18`. Must not
    ///               be rebasing (undetectable onchain; a deployment requirement).
    /// @param supply The total, fixed claim supply — the full liability. Minted in
    ///               its entirety to the creator (`msg.sender`) at construction.
    /// @param name_ Claim token name.
    /// @param symbol_ Claim token symbol.
    constructor(IERC20 _asset, uint256 supply, string memory name_, string memory symbol_) {
        uint8 d = _asset.decimals();
        if (d > 18) revert DecimalsTooHigh();
        asset = _asset;
        admin = msg.sender;
        ONE = 10 ** d;
        // Deploy the token here so the binding is 1:1 and correct atomically, and
        // mint the entire supply to the creator in the same transaction.
        claim = new RecoveryClaim(address(this), msg.sender, supply, name_, symbol_, d);
    }

    /// @notice Open redemption, permanently. One-way, irreversible. Flip this only
    ///         after the claim tokens have been distributed, so a creator holding
    ///         the full supply cannot drain the pot first.
    function finalize() external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        emit Finalized();
    }

    /// @notice Burn `amount` of the caller's claim tokens and send the pro-rata
    ///         share of the pot to `to`. Reverts while not finalised.
    /// @dev    Floor division; `assets` computed from the pre-burn balance and
    ///         supply. Redemption is price-neutral by construction, so there is no
    ///         slippage parameter and no MEV surface (invariant I1).
    function redeem(uint256 amount, address to) external nonReentrant returns (uint256 assets) {
        if (!finalized) revert NotFinalized();
        uint256 supply = claim.totalSupply();
        assets = amount * asset.balanceOf(address(this)) / supply; // floor, pre-burn
        claim.burn(msg.sender, amount);
        address(asset).safeTransfer(to, assets);
        emit Redeemed(msg.sender, amount, assets);
    }

    /// @notice Asset units payable per one whole claim token, at call time.
    /// @dev    Live pot balance over live supply. Returns 0 when supply is 0.
    function pricePerClaim() public view returns (uint256) {
        uint256 supply = claim.totalSupply();
        if (supply == 0) return 0;
        return asset.balanceOf(address(this)) * ONE / supply;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { RecoveryClaim } from "./RecoveryClaim.sol";

/// @title RecoveryEscrow
/// @notice Holds a pot of a single asset and owns the only mint/burn rights over
///         a `RecoveryClaim` token that represents a pro-rata claim on that pot.
///         After finalisation the only holder action is `redeem`: burn `amount`
///         of the claim token, receive `amount * poolBalance / totalSupply` of
///         the asset. No proofs, no allowlist, no claim window.
/// @dev    The load-bearing rule: `poolBalance` is an internal ledger and is
///         never `asset.balanceOf(address(this))`. Assets arriving by direct
///         transfer are *uncredited* and pay out to nobody until an admin
///         decides to credit them. See README §"accounting separation".
contract RecoveryEscrow is ReentrancyGuard {
    using SafeTransferLib for address;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage — this is the complete set. Nothing else. (Build spec §4)
    // ─────────────────────────────────────────────────────────────────────────

    IERC20 public immutable asset;
    RecoveryClaim public immutable claim;
    address public immutable admin;

    /// @dev One whole claim token == one whole asset unit == 10**decimals, since
    ///      `claim.decimals() == asset.decimals()`. Fixes the price fixed-point.
    uint256 public immutable ONE;

    bool public finalized;
    uint256 public poolBalance;
    uint256 public totalInflows;
    uint256 public totalPayouts;
    uint256 public totalSwept;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Attribution (who the money is from) is `from` here, resolved offchain.
    ///      The contract does not otherwise record provenance.
    event Funded(address indexed from, uint256 amount);
    event Credited(uint256 amount);
    event Swept(address indexed to, uint256 amount);
    event Distributed(address indexed to, uint256 amount);
    event Corrected(address indexed from, address indexed to, uint256 amount);
    event Finalized();
    event Redeemed(address indexed holder, uint256 amount, uint256 assets);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyAdmin();
    error NotFinalized();
    error AlreadyFinalized();
    error LengthMismatch();
    error InexactTransfer();
    error ExceedsUncredited();
    error DecimalsTooHigh();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier notFinalized() {
        if (finalized) revert AlreadyFinalized();
        _;
    }

    /// @param _asset The single pot asset. Must have `decimals() <= 18`. Must not
    ///               be fee-on-transfer (rejected at `fund` time) and must not be
    ///               rebasing (undetectable onchain; a deployment requirement).
    /// @param name_ Claim token name.
    /// @param symbol_ Claim token symbol.
    constructor(IERC20 _asset, string memory name_, string memory symbol_) {
        uint8 d = _asset.decimals();
        if (d > 18) revert DecimalsTooHigh();
        asset = _asset;
        admin = msg.sender;
        ONE = 10 ** d;
        // Deploy the token here so the binding is 1:1 and correct atomically:
        // `claim` is immutable on the escrow and `escrow` is immutable on the
        // token. No post-deploy setter, no CREATE2 precompute, no init window.
        claim = new RecoveryClaim(address(this), name_, symbol_, d);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Distribution — admin, pre-finalisation only
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Mint claim tokens to a batch of loss-bearing addresses. Callable
    ///         repeatedly until finalisation. A duplicate address across batches
    ///         accumulates (ERC-20 `_mint` adds), it does not overwrite.
    function distribute(address[] calldata to, uint256[] calldata amounts)
        external
        onlyAdmin
        notFinalized
    {
        if (to.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < to.length; ++i) {
            claim.mint(to[i], amounts[i]);
            emit Distributed(to[i], amounts[i]);
        }
    }

    /// @notice Move an allocation from one address to another without changing
    ///         total supply — for errors found after a batch lands.
    function correct(address from, address to, uint256 amount) external onlyAdmin notFinalized {
        claim.burn(from, amount);
        claim.mint(to, amount);
        emit Corrected(from, to, amount);
    }

    /// @notice Finalise supply, permanently. After this no mint and no admin burn
    ///         is possible; supply is monotonically non-increasing and `redeem`
    ///         becomes available. One-way, irreversible.
    function finalize() external onlyAdmin notFinalized {
        finalized = true;
        claim.closeMinting();
        emit Finalized();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Funding
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pull `amount` of the asset from the caller into the pot and credit
    ///         it. Permissionless. Reverts if the received amount differs from
    ///         `amount`, which rejects fee-on-transfer assets.
    function fund(uint256 amount) external {
        uint256 before = asset.balanceOf(address(this));
        address(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - before != amount) revert InexactTransfer();
        poolBalance += amount;
        totalInflows += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Credit up to `amount` of currently-uncredited balance into the
    ///         pot, making it redeemable. Admin-only — crediting is a decision,
    ///         not an automatic consequence of arrival.
    function creditUncredited(uint256 amount) external onlyAdmin {
        if (amount > uncredited()) revert ExceedsUncredited();
        poolBalance += amount;
        totalInflows += amount;
        emit Credited(amount);
    }

    /// @notice Send `amount` of currently-uncredited balance out to `to`. Admin
    ///         only. Cannot touch credited (redeemable) funds. Counted in both
    ///         `totalInflows` and `totalSwept` so the conservation invariant I3
    ///         holds (value that entered the accounting system and left it).
    function sweepUncredited(address to, uint256 amount) external onlyAdmin {
        if (amount > uncredited()) revert ExceedsUncredited();
        totalInflows += amount;
        totalSwept += amount;
        address(asset).safeTransfer(to, amount);
        emit Swept(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The only holder action
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Burn `amount` of the caller's claim tokens and send the pro-rata
    ///         share of the pot to `to`. Reverts while not finalised.
    /// @dev    Floor division, `assets` computed before any state change, both
    ///         `poolBalance` and `supply` pre-mutation. Redemption is
    ///         price-neutral by construction, so there is no slippage parameter
    ///         and no MEV surface (build spec §4.2, invariant I1).
    function redeem(uint256 amount, address to) external nonReentrant returns (uint256 assets) {
        if (!finalized) revert NotFinalized();
        uint256 supply = claim.totalSupply();
        assets = amount * poolBalance / supply; // floor, pre-burn, pre-decrement
        poolBalance -= assets;
        totalPayouts += assets;
        claim.burn(msg.sender, amount);
        address(asset).safeTransfer(to, assets);
        emit Redeemed(msg.sender, amount, assets);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Asset units payable per one whole claim token, at call time.
    /// @dev    Both terms are live: `poolBalance` (already reduced by every prior
    ///         payout) over `claim.totalSupply()` (already reduced by every prior
    ///         burn). Never `totalInflows`, never a fixed original-supply constant.
    function pricePerClaim() public view returns (uint256) {
        uint256 supply = claim.totalSupply();
        if (supply == 0) return 0;
        return poolBalance * ONE / supply;
    }

    /// @notice Asset present at this address but not credited to the pool, and so
    ///         not redeemable. Never negative: `poolBalance <= balanceOf` always.
    function uncredited() public view returns (uint256) {
        return asset.balanceOf(address(this)) - poolBalance;
    }
}

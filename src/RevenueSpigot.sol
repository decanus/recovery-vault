// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "./interfaces/IERC20.sol";

/// @title RevenueSpigot
/// @notice Intercepts a fixed share of protocol revenue from registered sources
///         and forwards it to the escrow by transfer — any asset held by the
///         escrow backs the claims. Independent of the escrow/claim pair;
///         deployable separately.
/// @dev    Source registration is append-only (sources can never be removed).
///         `route` is permissionless. `shareBps` changes are timelocked and
///         clamped to a fixed `[MIN_SHARE_BPS, MAX_SHARE_BPS]` range so the admin
///         cannot zero the intercept even after the delay.
contract RevenueSpigot {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;

    /// @notice Timelock delay applied to every `shareBps` change.
    uint256 public constant SHARE_TIMELOCK = 2 days;

    IERC20 public immutable asset;
    address public immutable escrow;
    address public immutable admin;

    /// @notice Fixed bounds on `shareBps`, set at deployment and never changeable.
    uint256 public immutable MIN_SHARE_BPS;
    uint256 public immutable MAX_SHARE_BPS;

    /// @notice Current intercepted share, in basis points.
    uint256 public shareBps;

    /// @notice Append-only set of authorised revenue sources.
    mapping(address => bool) public registered;

    // Pending timelocked share change.
    bool public changePending;
    uint256 public queuedShareBps;
    uint256 public queuedAt;

    event SourceRegistered(address indexed source);
    event Routed(address indexed source, uint256 toEscrow);
    event ShareChangeQueued(uint256 newShareBps, uint256 executableAt);
    event ShareChangeExecuted(uint256 newShareBps);

    error OnlyAdmin();
    error NotRegistered();
    error AlreadyRegistered();
    error ShareOutOfRange();
    error NoChangePending();
    error TimelockNotElapsed();
    error NothingToRoute();
    error InvalidBounds();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @param _asset The revenue asset (must match the escrow's asset).
    /// @param _escrow The escrow address that receives the intercepted share.
    /// @param minShareBps Lower clamp on `shareBps`, fixed forever.
    /// @param maxShareBps Upper clamp on `shareBps`, fixed forever.
    /// @param initialShareBps Starting share; must lie within the clamp range.
    constructor(
        IERC20 _asset,
        address _escrow,
        uint256 minShareBps,
        uint256 maxShareBps,
        uint256 initialShareBps
    ) {
        if (!(minShareBps <= maxShareBps && maxShareBps <= BPS && minShareBps > 0)) {
            revert InvalidBounds();
        }
        if (initialShareBps < minShareBps || initialShareBps > maxShareBps) {
            revert ShareOutOfRange();
        }
        asset = _asset;
        escrow = _escrow;
        admin = msg.sender;
        MIN_SHARE_BPS = minShareBps;
        MAX_SHARE_BPS = maxShareBps;
        shareBps = initialShareBps;
    }

    /// @notice Register a revenue source. Append-only: a source can never be
    ///         removed once registered.
    function register(address source) external onlyAdmin {
        if (registered[source]) revert AlreadyRegistered();
        registered[source] = true;
        emit SourceRegistered(source);
    }

    /// @notice Transfer the intercepted share of a registered source's approved
    ///         balance to the escrow. Permissionless. The non-intercepted
    ///         remainder is left with the source.
    /// @dev    The source must have approved this spigot to pull. The amount
    ///         considered is `min(source balance, source allowance to spigot)`.
    function route(address source) external returns (uint256 toEscrow) {
        if (!registered[source]) revert NotRegistered();
        uint256 bal = asset.balanceOf(source);
        uint256 allowed = asset.allowance(source, address(this));
        uint256 amount = bal < allowed ? bal : allowed;
        toEscrow = amount * shareBps / BPS;
        if (toEscrow == 0) revert NothingToRoute();
        // Transfer straight to the escrow — any asset held by the escrow backs
        // the claims, so no intermediate hop or `fund` call is needed.
        address(asset).safeTransferFrom(source, escrow, toEscrow);
        emit Routed(source, toEscrow);
    }

    /// @notice Queue a `shareBps` change. Reverts if the new value is outside the
    ///         fixed clamp range. The queued value is public during the delay.
    function queueShareChange(uint256 newShareBps) external onlyAdmin {
        if (newShareBps < MIN_SHARE_BPS || newShareBps > MAX_SHARE_BPS) {
            revert ShareOutOfRange();
        }
        changePending = true;
        queuedShareBps = newShareBps;
        queuedAt = block.timestamp;
        emit ShareChangeQueued(newShareBps, block.timestamp + SHARE_TIMELOCK);
    }

    /// @notice Apply a previously-queued `shareBps` change once the timelock has
    ///         elapsed.
    function executeShareChange() external onlyAdmin {
        if (!changePending) revert NoChangePending();
        if (block.timestamp < queuedAt + SHARE_TIMELOCK) revert TimelockNotElapsed();
        shareBps = queuedShareBps;
        changePending = false;
        emit ShareChangeExecuted(shareBps);
    }
}

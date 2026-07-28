// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { RecoveryNote } from "./RecoveryNote.sol";

/// @title RecoveryPool
/// @notice Socialises a recovery cost onto LPs, who are repaid with interest out
///         of protocol revenue. LPs deposit the asset during a funding window and
///         receive `RecoveryNote` 1:1. `close()` pushes the entire raise to the
///         escrow in one transfer — making claimants whole immediately — and
///         starts interest accruing on the obligation the protocol now owes the
///         LPs. Revenue is then repaid by transferring the asset to this address,
///         and LPs draw it down pro-rata as it arrives.
/// @dev    Auxiliary: nothing in `RecoveryEscrow` / `RecoveryClaim` /
///         `RevenueSpigot` knows this contract exists. The escrow simply sees
///         asset arrive, exactly as it would from any other funder. A deployment
///         may use the pool or not; the escrow is unchanged either way.
///
///         Like the escrow, the pool is **balance-backed**: repayment is just a
///         transfer to this address, with no `repay` entrypoint and no
///         credited/uncredited split. The same consequence applies — asset sent
///         here is irreversibly LP money (up to the outstanding obligation; the
///         excess is forwarded on to the escrow, never returned to the sender).
///
///         There is no on-chain mechanism compelling anyone to repay. Absent a
///         `RevenueSpigot` pointed at this address, the obligation tracked here
///         is an accounting record of a promise, not an enforceable lien. LPs
///         underwrite that.
contract RecoveryPool is ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;

    /// @notice Interest year. Accrual is `debt * RATE_BPS * dt / (BPS * YEAR)`.
    uint256 public constant YEAR = 365 days;

    IERC20 public immutable asset;
    RecoveryNote public immutable note;
    address public immutable admin;

    /// @notice Receives the raise at `close()`, and any repayment beyond what the
    ///         LPs are owed. Intended to be a `RecoveryEscrow`, but the pool never
    ///         calls into it — a plain transfer is the whole integration.
    address public immutable escrow;

    /// @dev One whole note == one whole asset unit == 10**decimals, since
    ///      `note.decimals() == asset.decimals()`. Fixes the obligation fixed-point.
    uint256 public immutable ONE;

    /// @notice Annual interest rate on the outstanding obligation, in bps. Fixed
    ///         forever at deployment.
    uint256 public immutable RATE_BPS;

    /// @notice Ceiling on total LP repayment, in bps of principal (>= 10000). At
    ///         15000 the protocol can never owe more than 1.5x what it borrowed,
    ///         however long repayment takes. Fixed forever at deployment.
    uint256 public immutable MAX_REPAYMENT_BPS;

    /// @notice Principal actually raised, set once at `close()`.
    uint256 public principal;

    /// @notice Outstanding obligation as of `lastAccrual` — unpaid principal plus
    ///         interest accrued and not yet drawn down. Repayment reduces it 1:1.
    uint256 public debt;

    /// @notice Cumulative interest ever added to `debt`, measured against
    ///         `maxInterest`.
    uint256 public interestAccrued;

    /// @notice Timestamp `debt` was last brought current.
    uint64 public lastAccrual;

    /// @notice One-way latch: the funding window is shut, the raise has been sent
    ///         to the escrow, interest is running and `redeem` is open.
    bool public closed;

    event Deposited(address indexed lp, uint256 amount);
    event Withdrawn(address indexed lp, uint256 amount);
    event Closed(uint256 principal, uint256 maxInterest);
    event Accrued(uint256 interest, uint256 debt);
    event Redeemed(address indexed lp, uint256 notes, uint256 assets);
    event ExcessForwarded(uint256 amount);

    error OnlyAdmin();
    error NotClosed();
    error AlreadyClosed();
    error DecimalsTooHigh();
    error InvalidRate();
    error InvalidCap();
    error NothingRaised();
    error NothingToRedeem();
    error NoExcess();

    /// @param _asset The asset LPs deposit and are repaid in. Must have
    ///               `decimals() <= 18` and must not be rebasing. Should match the
    ///               escrow's asset, since the raise is transferred straight there.
    /// @param _escrow Receives the raise at close and any over-repayment after.
    /// @param rateBps Annual rate on the outstanding obligation. `0 < rate <= BPS`.
    /// @param maxRepaymentBps Ceiling on total repayment as bps of principal;
    ///                        must be `>= BPS` (10000 = principal only, no interest).
    /// @param name_ Note token name.
    /// @param symbol_ Note token symbol.
    constructor(
        IERC20 _asset,
        address _escrow,
        uint256 rateBps,
        uint256 maxRepaymentBps,
        string memory name_,
        string memory symbol_
    ) {
        uint8 d = _asset.decimals();
        if (d > 18) revert DecimalsTooHigh();
        if (rateBps == 0 || rateBps > BPS) revert InvalidRate();
        if (maxRepaymentBps < BPS) revert InvalidCap();
        asset = _asset;
        escrow = _escrow;
        admin = msg.sender;
        ONE = 10 ** d;
        RATE_BPS = rateBps;
        MAX_REPAYMENT_BPS = maxRepaymentBps;
        note = new RecoveryNote(address(this), name_, symbol_, d);
    }

    // ── Funding window ──────────────────────────────────────────────────────

    /// @notice Deposit `amount` of the asset and receive notes 1:1. Open only
    ///         until `close()`.
    /// @dev    Notes are minted against the measured balance delta, not the stated
    ///         amount, so a fee-on-transfer asset mints exactly what arrived.
    function deposit(uint256 amount) external nonReentrant returns (uint256 minted) {
        if (closed) revert AlreadyClosed();
        uint256 before = asset.balanceOf(address(this));
        address(asset).safeTransferFrom(msg.sender, address(this), amount);
        minted = asset.balanceOf(address(this)) - before;
        note.mint(msg.sender, minted);
        emit Deposited(msg.sender, minted);
    }

    /// @notice Burn `amount` notes and take the deposit back. Open only until
    ///         `close()` — nothing is committed while the window is open, so
    ///         withdrawal is unconditional and 1:1.
    function withdraw(uint256 amount) external nonReentrant {
        if (closed) revert AlreadyClosed();
        note.burn(msg.sender, amount);
        address(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Shut the window, send the entire raise to the escrow, and start the
    ///         clock. One-way, irreversible, admin-only.
    /// @dev    No target is enforced: a short raise simply funds the escrow
    ///         partially, which prices its claims correctly on its own. `principal`
    ///         equals `note.totalSupply()` here, so the obligation per note starts
    ///         at exactly 1.0 and only rises with interest.
    function close() external nonReentrant {
        if (msg.sender != admin) revert OnlyAdmin();
        if (closed) revert AlreadyClosed();
        uint256 raised = asset.balanceOf(address(this));
        if (raised == 0) revert NothingRaised();

        closed = true;
        principal = raised;
        debt = raised;
        lastAccrual = uint64(block.timestamp);
        note.closeMinting();

        address(asset).safeTransfer(escrow, raised);
        emit Closed(raised, maxInterest());
    }

    // ── Accrual ─────────────────────────────────────────────────────────────

    /// @notice Bring `debt` current. Permissionless; called at the top of every
    ///         mutating post-close entrypoint.
    /// @dev    Linear between touches, so the obligation compounds once per touch.
    ///         Because anyone may call this, the effective rate should be priced as
    ///         continuously compounded — that is its upper bound, and it is capped
    ///         in absolute terms by `maxInterest` regardless.
    /// @return owed The obligation after accrual, so callers that immediately need
    ///         it do not have to re-derive it through `totalOwed()` — which would
    ///         re-read storage the external calls in between have already
    ///         invalidated for the optimiser.
    function accrue() public returns (uint256 owed) {
        if (!closed) return 0;
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return debt;
        lastAccrual = uint64(block.timestamp);

        uint256 interest = _pendingInterest(dt);
        if (interest == 0) return debt;
        owed = debt + interest;
        debt = owed;
        interestAccrued += interest;
        emit Accrued(interest, owed);
    }

    /// @dev Interest for `dt` seconds on the current `debt`, clamped so cumulative
    ///      interest never exceeds `maxInterest()`.
    function _pendingInterest(uint256 dt) internal view returns (uint256 interest) {
        uint256 headroom = maxInterest() - interestAccrued;
        if (headroom == 0) return 0;
        interest = debt * RATE_BPS * dt / (BPS * YEAR);
        if (interest > headroom) interest = headroom;
    }

    // ── Repayment draw-down ─────────────────────────────────────────────────

    /// @notice Burn notes against whatever repayment has arrived and take the
    ///         pro-rata share of it.
    /// @dev    The redeemer takes their pro-rata slice of available cash but burns
    ///         only the fraction of their notes that the cash repaid, keeping the
    ///         rest as a claim on the unpaid remainder. This makes redemption
    ///         obligation-neutral: `debt / supply` is unchanged (up to dust), so
    ///         drawing early neither dilutes nor enriches anyone — exactly the
    ///         property `RecoveryEscrow.redeem` has for `pricePerClaim`.
    ///
    ///         Rounding: `assets` floors and the burn ceils, so dust always favours
    ///         the holders who stay, and the redeemer pays it.
    function redeem(uint256 amount, address to)
        external
        nonReentrant
        returns (uint256 assets, uint256 burned)
    {
        if (!closed) revert NotClosed();
        uint256 owed = accrue();
        (assets, burned) = _previewRedeem(amount, owed);
        if (assets == 0) revert NothingToRedeem();

        debt = owed - assets;
        note.burn(msg.sender, burned);
        address(asset).safeTransfer(to, assets);
        emit Redeemed(msg.sender, burned, assets);
    }

    /// @notice Preview `redeem(amount, …)` at the current block: the asset paid out
    ///         and the notes it costs. Includes interest pending since `lastAccrual`.
    function previewRedeem(uint256 amount) external view returns (uint256 assets, uint256 burned) {
        return _previewRedeem(amount, totalOwed());
    }

    function _previewRedeem(uint256 amount, uint256 owed)
        internal
        view
        returns (uint256 assets, uint256 burned)
    {
        uint256 supply = note.totalSupply();
        if (supply == 0 || owed == 0) return (0, 0);

        uint256 cash = _drawableCash(owed);
        assets = amount * cash / supply; // floor
        // `burned <= ceil(amount * cash / owed) <= amount`, since `_drawableCash`
        // caps `cash` at `owed`. Left unguarded: a clamp here could only ever mask
        // a broken proof by silently burning too few notes, which would break
        // obligation-neutrality — reverting on the burn is the safer failure.
        burned = FixedPointMathLib.mulDivUp(assets, supply, owed); // ceil
    }

    /// @dev Repayment sitting in the pool that belongs to the LPs: the balance,
    ///      capped at the outstanding obligation. Anything above the cap is the
    ///      escrow's, and `forwardExcess` sweeps it there.
    function _drawableCash(uint256 owed) internal view returns (uint256 cash) {
        cash = asset.balanceOf(address(this));
        if (cash > owed) cash = owed;
    }

    /// @notice Push any repayment beyond the outstanding obligation on to the
    ///         escrow. Permissionless.
    /// @dev    Once every note is burned the obligation is discharged, so the whole
    ///         balance — including any dust `debt` left by rounding — belongs to the
    ///         escrow. This is the terminal state: the pool becomes a pass-through
    ///         to the claimants, which is the right resting place for revenue that
    ///         keeps arriving after the LPs are square.
    function forwardExcess() external nonReentrant returns (uint256 excess) {
        if (!closed) revert NotClosed();
        uint256 owed = accrue();

        uint256 cash = asset.balanceOf(address(this));
        if (note.totalSupply() == 0) {
            debt = 0;
            excess = cash;
        } else {
            excess = cash > owed ? cash - owed : 0;
        }
        if (excess == 0) revert NoExcess();

        address(asset).safeTransfer(escrow, excess);
        emit ExcessForwarded(excess);
    }

    // ── Views ───────────────────────────────────────────────────────────────

    /// @notice Hard ceiling on cumulative interest — the whole premium the protocol
    ///         can ever owe. Derived from `principal` and the immutable
    ///         `MAX_REPAYMENT_BPS`, so it is fixed the moment `close()` runs and 0
    ///         before it.
    function maxInterest() public view returns (uint256) {
        return principal * (MAX_REPAYMENT_BPS - BPS) / BPS;
    }

    /// @notice The outstanding obligation at call time, including interest pending
    ///         since `lastAccrual`.
    function totalOwed() public view returns (uint256) {
        if (!closed) return 0;
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return debt;
        return debt + _pendingInterest(dt);
    }

    /// @notice Asset units owed per one whole note, at call time. The direct
    ///         analogue of `RecoveryEscrow.pricePerClaim`, except it rises with
    ///         time (interest) and is unchanged by redemption.
    function owedPerNote() public view returns (uint256) {
        uint256 supply = note.totalSupply();
        if (supply == 0) return 0;
        return totalOwed() * ONE / supply;
    }

    /// @notice Asset units currently repaid and drawable per one whole note.
    ///         Rises as revenue arrives, falls as LPs draw it down.
    function cashPerNote() public view returns (uint256) {
        uint256 supply = note.totalSupply();
        if (supply == 0) return 0;
        return _drawableCash(totalOwed()) * ONE / supply;
    }
}

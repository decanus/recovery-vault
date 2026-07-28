// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { RecoveryPool } from "../../../src/RecoveryPool.sol";
import { RecoveryNote } from "../../../src/RecoveryNote.sol";
import { RecoveryEscrow } from "../../../src/RecoveryEscrow.sol";
import { IERC20 } from "../../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

/// @title PoolHandler
/// @notice Drives the LP pool through its whole life: an open funding window with
///         deposits and withdrawals, `close()` (which ships the raise to a real
///         escrow), then an arbitrary repayment schedule interleaved with time,
///         draw-downs, note transfers and excess forwarding — including the
///         terminal state where every note is burned. The handler *is* the pool
///         admin (it deploys the pool), mirroring the real deployment.
/// @dev    Violations are recorded as ghost flags rather than asserted inline:
///         under `fail_on_revert = false` an inline assertion revert would be
///         swallowed as "just another reverting call". `PoolInvariants` asserts
///         the flags.
contract PoolHandler is CommonBase, StdCheats, StdUtils {
    RecoveryPool public immutable pool;
    RecoveryNote public immutable note;
    RecoveryEscrow public immutable escrow;
    MockERC20 public immutable asset;

    uint256 internal constant LIABILITY = 1_000_000_000;
    uint256 internal constant RATE_BPS = 1500; // 15% / yr
    uint256 internal constant CAP_BPS = 13_000; // 1.3x principal, ever

    address[8] public actors;

    // ── Conservation ghosts ─────────────────────────────────────────────────
    uint256 public ghost_deposited; // asset in, via deposit
    uint256 public ghost_withdrawn; // asset out, via withdraw (window open)
    uint256 public ghost_repaid; // asset in, via revenue transfer
    uint256 public ghost_paidToLPs; // asset out, via redeem
    uint256 public ghost_toEscrow; // asset out, via close + forwardExcess

    /// @dev Dust obligation written off when the last note is burned. Keeps the
    ///      obligation identity exact rather than merely bounded.
    uint256 public ghost_writtenOff;

    // ── Coverage ghosts ─────────────────────────────────────────────────────
    uint256 public ghost_closedAt;
    uint256 public ghost_preCloseRedeemAttempts;
    uint256 public ghost_postCloseDepositAttempts;
    bool public ghost_reachedZeroSupply;
    bool public ghost_reachedCap;
    bool public ghost_fullyCovered;

    // ── Violation flags (asserted by PoolInvariants) ────────────────────────
    bool public flag_p3_redeemBeforeClose;
    bool public flag_p3_depositAfterClose;
    bool public flag_p4_obligationFell;
    bool public flag_p5_burnExceededOffer;
    bool public flag_p5_previewMismatch;
    bool public flag_p7_escrowLostGround;

    // ── Revert-rate accounting ──────────────────────────────────────────────
    uint256 public totalActions;
    uint256 public totalReverts;

    modifier countCall() {
        ++totalActions;
        _;
    }

    constructor() {
        asset = new MockERC20("USD Coin", "USDC", 6);
        escrow = new RecoveryEscrow(IERC20(address(asset)), LIABILITY, "Recovery Claim", "rcUSDC");
        pool = new RecoveryPool(
            IERC20(address(asset)), address(escrow), RATE_BPS, CAP_BPS, "Recovery Note", "rnUSDC"
        );
        note = pool.note();

        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0x2000 + i));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, 7)];
    }

    // ── Funding window ──────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external countCall {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 20_000_000);

        asset.mint(a, amount);
        vm.startPrank(a);
        asset.approve(address(pool), amount);

        if (pool.closed()) {
            // Probe, not a mistake: the window must be shut forever.
            ++ghost_postCloseDepositAttempts;
            (bool ok,) = address(pool).call(abi.encodeCall(RecoveryPool.deposit, (amount)));
            if (ok) flag_p3_depositAfterClose = true;
            vm.stopPrank();
            return;
        }

        try pool.deposit(amount) returns (uint256 minted) {
            ghost_deposited += minted;
        } catch {
            ++totalReverts;
        }
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external countCall {
        if (pool.closed()) return;
        address a = _actor(actorSeed);
        uint256 bal = note.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(a);
        try pool.withdraw(amount) {
            ghost_withdrawn += amount;
        } catch {
            ++totalReverts;
        }
    }

    function close() external countCall {
        if (pool.closed() || asset.balanceOf(address(pool)) == 0) return;
        try pool.close() {
            ghost_closedAt = block.timestamp;
            ghost_toEscrow += pool.principal();
        } catch {
            ++totalReverts;
        }
    }

    // ── Post-close ──────────────────────────────────────────────────────────

    /// @dev Protocol revenue: a plain transfer in. There is no `repay` entrypoint.
    ///      Bounded well above the plausible raise so campaigns reach the states
    ///      that only over-repayment produces: full discharge, and forwarding the
    ///      overflow on to the escrow.
    function repay(uint256 amount) external countCall {
        amount = bound(amount, 1, 400_000_000);
        asset.mint(address(pool), amount);
        ghost_repaid += amount;
    }

    function advanceTime(uint256 dt) external countCall {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1 hours, 120 days));
    }

    function accrue() external countCall {
        pool.accrue();
        if (pool.interestAccrued() == pool.maxInterest() && pool.closed()) {
            ghost_reachedCap = true;
        }
    }

    function redeem(uint256 actorSeed, uint256 amount) external countCall {
        address a = _actor(actorSeed);
        uint256 bal = note.balanceOf(a);

        if (!pool.closed()) {
            // Probe: drawing down before the raise is committed must be impossible.
            ++ghost_preCloseRedeemAttempts;
            uint256 offer = bal == 0 ? 1 : bal;
            vm.prank(a);
            (bool ok,) = address(pool).call(abi.encodeCall(RecoveryPool.redeem, (offer, a)));
            if (ok) flag_p3_redeemBeforeClose = true;
            return;
        }
        if (bal == 0) return;
        // Bias a third of draws to a full exit, so campaigns actually reach the
        // discharged (`totalSupply == 0`) terminal state rather than only ever
        // nibbling at it.
        _redeemAs(a, amount % 3 == 0 ? bal : bound(amount, 1, bal));
    }

    /// @dev Every LP exits at once. A single-selector route to the discharged
    ///      terminal state — a uniform fuzzer would otherwise have to draw eight
    ///      consecutive full exits with no interest accruing in between, which it
    ///      effectively never does. That state is where the dust write-off (P1)
    ///      and the escrow pass-through (P7) live, so it needs to be reachable.
    function dischargeAll() external countCall {
        if (!pool.closed()) return;
        for (uint256 i; i < 8; ++i) {
            uint256 bal = note.balanceOf(actors[i]);
            if (bal != 0) _redeemAs(actors[i], bal);
        }
    }

    function _redeemAs(address a, uint256 amount) internal {
        uint256 owedPerNoteBefore = pool.owedPerNote();
        uint256 escrowBefore = asset.balanceOf(address(escrow));
        (uint256 pAssets, uint256 pBurn) = pool.previewRedeem(amount);
        // Nothing repaid yet (or the slice floors to zero): the call would revert
        // by design, and firing it anyway would swamp the revert-rate guard —
        // `dischargeAll` alone would contribute eight reverts per action. The
        // revert itself is pinned in `test_redeem_cannotDrawMoreThanOwed`.
        if (pAssets == 0) return;
        if (pool.cashPerNote() == owedPerNoteBefore) ghost_fullyCovered = true;

        vm.prank(a);
        try pool.redeem(amount, a) returns (uint256 assets, uint256 burned) {
            ghost_paidToLPs += assets;

            if (burned > amount) flag_p5_burnExceededOffer = true;
            if (assets != pAssets || burned != pBurn) flag_p5_previewMismatch = true;
            // Obligation per note is unchanged by a draw-down (dust aside, which
            // may only ever move it up).
            if (note.totalSupply() > 0 && pool.owedPerNote() < owedPerNoteBefore) {
                flag_p4_obligationFell = true;
            }
            if (note.totalSupply() == 0) ghost_reachedZeroSupply = true;
            // A draw-down is LP money leaving; it must never come out of the
            // escrow's pot.
            if (asset.balanceOf(address(escrow)) < escrowBefore) flag_p7_escrowLostGround = true;
        } catch {
            ++totalReverts;
        }
    }

    function forwardExcess() external countCall {
        if (!pool.closed()) return;
        bool discharged = note.totalSupply() == 0;
        uint256 owedBefore = pool.totalOwed();

        try pool.forwardExcess() returns (uint256 excess) {
            ghost_toEscrow += excess;
            // The last note burned discharges the obligation; any dust left by
            // rounding is written off to the escrow with the cash.
            if (discharged) ghost_writtenOff += owedBefore;
        } catch {
            ++totalReverts;
        }
    }

    function transferNote(uint256 fromSeed, uint256 toSeed, uint256 amount) external countCall {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = note.balanceOf(from);
        if (bal == 0 || from == to) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        try note.transfer(to, amount) { }
        catch {
            ++totalReverts;
        }
    }
}

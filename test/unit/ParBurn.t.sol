// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { RecoveryPool } from "../../src/RecoveryPool.sol";
import { RecoveryNote } from "../../src/RecoveryNote.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @dev A paper experiment plus one live check. The question: can the escrow be
///      made to pay every claimant their face-share of *everything that ever
///      entered the pot*, rather than their share of whatever happened to be
///      sitting there when they redeemed?
///
///      Rule A (shipped): burn `amount` — the tokens offered.
///      Rule B (candidate): burn `assets` — the tokens the payout actually
///      retired. Well-defined without new state, since the claim is already at
///      par (`claim.decimals == asset.decimals`, initial supply == the full
///      liability), so one token is one asset unit of face.
///
///      Result: **neither rule delivers the property below full recovery.** Rule
///      A underpays whoever redeems early; rule B overpays whoever redeems most
///      often. They agree, and are both exact, only at 100% recovery.
contract ParBurnTest is BaseTest {
    struct Sim {
        uint256 pot;
        uint256 supply;
        uint256[2] face;
        uint256[2] got;
        uint256 inflows;
    }

    function _init(uint256 f0, uint256 f1) internal pure returns (Sim memory s) {
        s.face[0] = f0;
        s.face[1] = f1;
        s.supply = f0 + f1;
    }

    function _fund(Sim memory s, uint256 amount) internal pure {
        s.pot += amount;
        s.inflows += amount;
    }

    /// @param parBurn false = rule A (burn what was offered), true = rule B.
    function _redeem(Sim memory s, uint256 who, uint256 amount, bool parBurn) internal pure {
        if (s.supply == 0 || amount == 0) return;
        if (amount > s.face[who]) amount = s.face[who];
        uint256 assets = amount * s.pot / s.supply;
        uint256 burn = parBurn ? assets : amount;
        if (burn > s.face[who]) burn = s.face[who]; // recovery > 100% guard
        s.pot -= assets;
        s.supply -= burn;
        s.face[who] -= burn;
        s.got[who] += assets;
    }

    /// @dev Both holders draw everything they can, repeatedly, until the pot
    ///      stops moving. Under rule B a single call never fully retires a claim
    ///      while recovery is below 100%, so "collect what you are owed" means
    ///      draining in a loop.
    function _drainBoth(Sim memory s, bool parBurn) internal pure {
        for (uint256 i; i < 400; ++i) {
            uint256 before = s.pot;
            _redeem(s, 0, s.face[0], parBurn);
            _redeem(s, 1, s.face[1], parBurn);
            if (s.pot == before) break;
        }
    }

    // ── Rule A: the early redeemer is cut out of later funding ──────────────

    function test_ruleA_earlyRedeemerMissesLaterFunding() public pure {
        Sim memory s = _init(50_000_000, 50_000_000);
        _fund(s, 30_000_000);
        _redeem(s, 0, 50_000_000, false);
        _fund(s, 30_000_000);
        _redeem(s, 1, 50_000_000, false);

        assertEq(s.got[0], 15_000_000, "alice");
        assertEq(s.got[1], 45_000_000, "bob");
        assertEq(s.got[0] + s.got[1], s.inflows, "aggregate conserves");
        assertLt(s.got[0], s.inflows / 2, "alice below her face-share");
    }

    // ── Rule B: the frequent redeemer takes from the patient one ────────────

    /// Rule B keeps the early redeemer's claim alive — but it also dilutes
    /// whoever stays. Paying `assets` and burning `assets` removes the *same*
    /// amount from pot and supply, and while the pot is smaller than the supply
    /// (i.e. recovery below 100%) that strictly lowers `pot / supply` for
    /// everyone left. So the draw is not neutral: it moves value to the drawer.
    function test_ruleB_drawLowersTheRecoveryRatioForEveryoneElse() public pure {
        Sim memory s = _init(50_000_000, 50_000_000);
        _fund(s, 30_000_000);

        uint256 ratioBefore = s.pot * 1e18 / s.supply; // 0.30
        _redeem(s, 0, 50_000_000, true);
        uint256 ratioAfter = s.pot * 1e18 / s.supply; // 0.176

        assertEq(s.got[0], 15_000_000, "same payout as rule A at this instant");
        assertEq(s.face[0], 35_000_000, "but 35M of face survives");
        assertLt(ratioAfter, ratioBefore, "rule B is dilutive, not neutral");
    }

    /// And that dilution compounds: the holder who redeems repeatedly ends up
    /// ahead of the one who waits, on identical face.
    function test_ruleB_overpaysTheFrequentRedeemer() public pure {
        Sim memory s = _init(50_000_000, 50_000_000);
        _fund(s, 30_000_000);
        _redeem(s, 0, 50_000_000, true); // alice draws early
        _fund(s, 30_000_000);
        _drainBoth(s, true); // then both collect everything

        assertGt(s.got[0], s.inflows / 2, "alice above her face-share");
        assertLt(s.got[1], s.inflows / 2, "bob below his");
        // Same direction as rule A, opposite sign: ~36.4M vs ~23.6M on 60M.
        assertGt(s.got[0], s.got[1]);
    }

    /// Both rules are exact — and identical — at 100% recovery. That is the only
    /// regime in which "your share of everything that ever arrived" is a
    /// well-defined thing a single burn rule can deliver.
    function test_bothRulesAgreeAtFullRecovery() public pure {
        Sim memory a = _init(50_000_000, 50_000_000);
        Sim memory b = _init(50_000_000, 50_000_000);
        _fund(a, 100_000_000);
        _fund(b, 100_000_000);
        _drainBoth(a, false);
        _drainBoth(b, true);

        assertEq(a.got[0], 50_000_000);
        assertEq(a.got[1], 50_000_000);
        assertEq(b.got[0], 50_000_000);
        assertEq(b.got[1], 50_000_000);
        assertEq(a.supply, 0);
        assertEq(b.supply, 0);
    }

    // ── The same race, on the shipped pool contract ─────────────────────────

    /// The pool uses rule B (that is what the proportional burn is), so it
    /// inherits the same property whenever repayment stalls below the full
    /// obligation: an LP who draws repeatedly out-earns one who waits. It is
    /// benign there only because the obligation is a debt that is expected to be
    /// repaid in full — at which point, per the test above, the race washes out.
    /// It would not be benign for a claim pot that simply stops at 60%.
    function test_pool_partialRepaymentIsADrainRace() public {
        RecoveryPool pool = new RecoveryPool(
            IERC20(address(asset)), address(0xDEAD), 1, 20_000, "Recovery Note", "rnUSDC"
        );
        RecoveryNote note = pool.note();

        asset.mint(alice, 50_000_000);
        asset.mint(bob, 50_000_000);
        vm.startPrank(alice);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        vm.startPrank(bob);
        asset.approve(address(pool), 50_000_000);
        pool.deposit(50_000_000);
        vm.stopPrank();
        pool.close();

        // One partial repayment, then repayment stops forever.
        asset.mint(address(pool), 30_000_000);

        // Alice draws repeatedly; bob draws once at the end.
        uint256 aliceGot;
        for (uint256 i; i < 12; ++i) {
            uint256 held = note.balanceOf(alice);
            if (held == 0) break;
            vm.prank(alice);
            try pool.redeem(held, alice) returns (uint256 a, uint256) {
                aliceGot += a;
            } catch {
                break;
            }
        }
        uint256 bobHeld = note.balanceOf(bob);
        vm.prank(bob);
        (uint256 bobGot,) = pool.redeem(bobHeld, bob);

        emit log_named_uint("alice (drew repeatedly)", aliceGot);
        emit log_named_uint("bob   (drew once)      ", bobGot);
        emit log_named_uint("left undrawn in pool   ", asset.balanceOf(address(pool)));

        assertGt(aliceGot, bobGot, "repeated draws beat a single one on equal notes");
        assertGt(aliceGot, 15_000_000, "alice took more than half of the 30M");
        assertLt(bobGot, 15_000_000, "bob took less");
        // Nothing is created; the shortfall is simply still sitting in the pool,
        // claimable by whatever notes remain.
        assertLe(aliceGot + bobGot, 30_000_000, "no assets conjured");
        assertEq(aliceGot + bobGot + asset.balanceOf(address(pool)), 30_000_000, "assets conserved");
    }
}

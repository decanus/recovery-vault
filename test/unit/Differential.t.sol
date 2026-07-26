// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";

/// @dev Fuzz the production `pricePerClaim`/`redeem` against a plain reference
///      model over random inflow/redeem sequences. Any divergence in numerator
///      or denominator (build spec §4.1) shows up here immediately.
contract DifferentialTest is BaseTest {
    uint256 internal refPool;
    uint256 internal refSupply;
    uint256 internal constant ONE = 1e6;

    function _refPrice() internal view returns (uint256) {
        if (refSupply == 0) return 0;
        return refPool * ONE / refSupply;
    }

    function testFuzz_differential(
        uint256[16] calldata ops,
        uint256 initialSupply,
        uint256 seedFund
    ) public {
        // One holder gets all the supply so we can redeem arbitrary amounts.
        initialSupply = bound(initialSupply, 1, 1e18);
        _distribute(alice, initialSupply);
        refSupply = initialSupply;

        uint256 firstFund = bound(seedFund, 0, 1e18);
        if (firstFund > 0) {
            _fund(admin, firstFund);
            refPool += firstFund;
        }

        escrow.finalize();

        assertEq(escrow.pricePerClaim(), _refPrice(), "initial price diverged");

        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 2;
            uint256 mag = ops[i] >> 1;

            if (op == 0) {
                // inflow
                uint256 amt = mag % 1e18;
                if (amt == 0) continue;
                _fund(admin, amt);
                refPool += amt;
            } else {
                // redeem
                uint256 bal = claim.balanceOf(alice);
                if (bal == 0) continue;
                uint256 amt = mag % (bal + 1);
                if (amt == 0) continue;

                uint256 expected = amt * refPool / refSupply;
                vm.prank(alice);
                uint256 got = escrow.redeem(amt, alice);
                assertEq(got, expected, "redeem payout diverged");
                refPool -= expected;
                refSupply -= amt;
            }

            assertEq(escrow.pricePerClaim(), _refPrice(), "price diverged after op");
            assertEq(escrow.poolBalance(), refPool, "poolBalance diverged");
            assertEq(claim.totalSupply(), refSupply, "supply diverged");
        }
    }
}

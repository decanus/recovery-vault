// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";

/// @dev Fuzz the production `pricePerClaim`/`redeem` against a plain reference
///      model over random inflow/redeem sequences. The pot is the escrow's asset
///      balance, so an inflow is a transfer into it.
contract DifferentialTest is BaseTest {
    uint256 internal refBal;
    uint256 internal refSupply;
    uint256 internal constant ONE = 1e6;

    function _refPrice() internal view returns (uint256) {
        if (refSupply == 0) return 0;
        return refBal * ONE / refSupply;
    }

    function testFuzz_differential(
        uint256[16] calldata ops,
        uint256 initialSupply,
        uint256 seedFund
    ) public {
        initialSupply = bound(initialSupply, 1, 1e18);
        _deploy(initialSupply);
        _give(alice, initialSupply); // one holder gets everything
        refSupply = initialSupply;

        uint256 firstFund = bound(seedFund, 0, 1e18);
        if (firstFund > 0) {
            _fundPot(firstFund);
            refBal += firstFund;
        }

        escrow.finalize();
        assertEq(escrow.pricePerClaim(), _refPrice(), "initial price diverged");

        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 2;
            uint256 mag = ops[i] >> 1;

            if (op == 0) {
                uint256 amt = mag % 1e18;
                if (amt == 0) continue;
                _fundPot(amt);
                refBal += amt;
            } else {
                uint256 bal = claim.balanceOf(alice);
                if (bal == 0) continue;
                uint256 amt = mag % (bal + 1);
                if (amt == 0) continue;

                uint256 expected = amt * refBal / refSupply;
                vm.prank(alice);
                uint256 got = escrow.redeem(amt, alice);
                assertEq(got, expected, "redeem payout diverged");
                refBal -= expected;
                refSupply -= amt;
            }

            assertEq(escrow.pricePerClaim(), _refPrice(), "price diverged after op");
            assertEq(asset.balanceOf(address(escrow)), refBal, "balance diverged");
            assertEq(claim.totalSupply(), refSupply, "supply diverged");
        }
    }
}

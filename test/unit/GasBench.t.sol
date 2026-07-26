// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "./Base.t.sol";
import { console } from "forge-std/Test.sol";

/// @dev Gas benchmark for `distribute` at batch sizes 50, 100, 250 so a deployer
///      can size batches against the target chain's block gas limit. Run with:
///        forge test --match-contract GasBenchTest -vv
contract GasBenchTest is BaseTest {
    function _bench(uint256 size) internal {
        address[] memory to = new address[](size);
        uint256[] memory amt = new uint256[](size);
        for (uint256 i; i < size; ++i) {
            to[i] = address(uint160(0x100000 + i));
            amt[i] = 1_000_000 + i;
        }
        uint256 g0 = gasleft();
        escrow.distribute(to, amt);
        uint256 used = g0 - gasleft();
        console.log("distribute batch size", size, "gas", used);
    }

    function test_gas_distribute_50() public {
        _bench(50);
    }

    function test_gas_distribute_100() public {
        _bench(100);
    }

    function test_gas_distribute_250() public {
        _bench(250);
    }
}

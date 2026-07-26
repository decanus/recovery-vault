// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Distribute } from "../../script/Distribute.s.sol";
import { RecoveryEscrow } from "../../src/RecoveryEscrow.sol";
import { RecoveryClaim } from "../../src/RecoveryClaim.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev Exercises the CSV parser and batched-distribute logic of the deploy
///      script end-to-end against a real escrow.
contract DistributeScriptTest is Test {
    Distribute internal script;
    RecoveryEscrow internal escrow;
    RecoveryClaim internal claim;
    MockERC20 internal asset;

    string internal constant CSV_PATH = "scratch_alloc.csv";

    // `DEFAULT_SENDER` (from forge-std) is the broadcaster `vm.startBroadcast()`
    // uses with no args.
    function setUp() public {
        script = new Distribute();
        asset = new MockERC20("USD Coin", "USDC", 6);
        // Deploy the escrow as the broadcaster so `run()`'s broadcast calls pass
        // `onlyAdmin` when the script is executed in-process.
        vm.prank(DEFAULT_SENDER);
        escrow = new RecoveryEscrow(IERC20(address(asset)), "Recovery Claim", "rcUSDC");
        claim = escrow.claim();
    }

    function test_parseAndDistribute_batches() public {
        // Build a CSV with a trailing newline and a duplicate address.
        string memory csv = string.concat(
            "0x0000000000000000000000000000000000000001,1000000\n",
            "0x0000000000000000000000000000000000000002,2500000\n",
            "0x0000000000000000000000000000000000000001,500000\n" // duplicate -> accumulates
        );
        vm.writeFile(CSV_PATH, csv);

        // The script runs from the escrow admin (this test contract deployed it,
        // but the script broadcasts as the default sender). Set env and grant the
        // script's default broadcaster admin by re-deploying from that address is
        // heavy; instead call the escrow's admin path by pranking the broadcast.
        vm.setEnv("ESCROW", vm.toString(address(escrow)));
        vm.setEnv("CSV", CSV_PATH);
        vm.setEnv("BATCH_SIZE", "2");

        // Called in-process: the external calls originate from `script`, which is
        // the escrow admin (see setUp), so `onlyAdmin` passes.
        script.run();

        assertEq(claim.balanceOf(address(1)), 1_500_000, "duplicate did not accumulate");
        assertEq(claim.balanceOf(address(2)), 2_500_000);
        assertEq(claim.totalSupply(), 4_000_000);

        vm.removeFile(CSV_PATH);
    }
}

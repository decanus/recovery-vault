// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { RecoveryEscrow } from "../src/RecoveryEscrow.sol";

/// @notice Reads a CSV of `address,amount` (one allocation per line, no header)
///         and drives batched `distribute` calls against a deployed escrow.
/// @dev    Env:
///           ESCROW     — deployed RecoveryEscrow address
///           CSV        — path to the allocation CSV (relative to project root)
///           BATCH_SIZE — allocations per distribute() call (default 100)
///         Run from the escrow admin key. Amounts are raw units (asset decimals).
///         Duplicate addresses across lines accumulate, matching on-chain
///         `distribute` semantics.
contract Distribute is Script {
    function run() external {
        RecoveryEscrow escrow = RecoveryEscrow(vm.envAddress("ESCROW"));
        string memory csv = vm.envString("CSV");
        uint256 batchSize = vm.envOr("BATCH_SIZE", uint256(100));
        require(batchSize > 0, "BATCH_SIZE=0");

        (address[] memory addrs, uint256[] memory amounts) = _parseCsv(csv);
        uint256 n = addrs.length;
        console.log("parsed allocations:", n);

        vm.startBroadcast();
        for (uint256 start; start < n; start += batchSize) {
            uint256 end = start + batchSize;
            if (end > n) end = n;
            uint256 len = end - start;

            address[] memory to = new address[](len);
            uint256[] memory amt = new uint256[](len);
            for (uint256 i; i < len; ++i) {
                to[i] = addrs[start + i];
                amt[i] = amounts[start + i];
            }
            escrow.distribute(to, amt);
            console.log("distributed batch", start / batchSize, "size", len);
        }
        vm.stopBroadcast();
    }

    /// @dev Two-pass CSV parse: count lines, then fill. Lines are `address,amount`.
    function _parseCsv(string memory path)
        internal
        view
        returns (address[] memory addrs, uint256[] memory amounts)
    {
        string memory data = vm.readFile(path);
        bytes memory b = bytes(data);

        // Pass 1: count non-empty lines.
        uint256 count;
        {
            uint256 lineLen;
            for (uint256 i; i < b.length; ++i) {
                if (b[i] == "\n") {
                    if (lineLen > 0) count++;
                    lineLen = 0;
                } else if (b[i] != "\r") {
                    lineLen++;
                }
            }
            if (lineLen > 0) count++; // last line without trailing newline
        }

        addrs = new address[](count);
        amounts = new uint256[](count);

        // Pass 2: split each line on the first comma.
        uint256 idx;
        uint256 lineStart;
        for (uint256 i; i <= b.length; ++i) {
            bool eol = i == b.length || b[i] == "\n";
            if (!eol) continue;

            uint256 lineEnd = i;
            // trim a trailing \r
            if (lineEnd > lineStart && b[lineEnd - 1] == "\r") lineEnd -= 1;

            if (lineEnd > lineStart) {
                (address who, uint256 amount) = _parseLine(b, lineStart, lineEnd);
                addrs[idx] = who;
                amounts[idx] = amount;
                idx++;
            }
            lineStart = i + 1;
        }
    }

    function _parseLine(bytes memory b, uint256 s, uint256 e)
        internal
        pure
        returns (address who, uint256 amount)
    {
        // find comma
        uint256 comma = e;
        for (uint256 i = s; i < e; ++i) {
            if (b[i] == ",") {
                comma = i;
                break;
            }
        }
        require(comma < e, "line missing comma");

        who = _parseAddress(b, s, comma);
        amount = _parseUint(b, comma + 1, e);
    }

    function _parseAddress(bytes memory b, uint256 s, uint256 e) internal pure returns (address) {
        // expects 0x-prefixed 40 hex chars
        require(e - s == 42 && b[s] == "0" && (b[s + 1] == "x" || b[s + 1] == "X"), "bad address");
        uint160 acc;
        for (uint256 i = s + 2; i < e; ++i) {
            acc = acc * 16 + uint160(_hexVal(b[i]));
        }
        return address(acc);
    }

    function _parseUint(bytes memory b, uint256 s, uint256 e) internal pure returns (uint256 acc) {
        for (uint256 i = s; i < e; ++i) {
            uint8 ch = uint8(b[i]);
            require(ch >= 0x30 && ch <= 0x39, "bad digit");
            acc = acc * 10 + (ch - 0x30);
        }
    }

    function _hexVal(bytes1 c) internal pure returns (uint8) {
        uint8 ch = uint8(c);
        if (ch >= 0x30 && ch <= 0x39) return ch - 0x30;
        if (ch >= 0x61 && ch <= 0x66) return ch - 0x61 + 10;
        if (ch >= 0x41 && ch <= 0x46) return ch - 0x41 + 10;
        revert("bad hex");
    }
}

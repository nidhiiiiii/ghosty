// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {AquiferStrategy} from "../src/libraries/AquiferStrategy.sol";

contract DeployForkDemo is Script {
    uint256 private constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 private constant BPS = 10_000;

    error InvalidSpread(uint256 spreadBps);
    error InvalidBound(uint256 boundBps);

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", ANVIL_PRIVATE_KEY);
        address vault = vm.envAddress("VAULT");
        uint256 spread = vm.envOr("SPREAD_BPS", uint256(15));
        uint256 bound = vm.envOr("BOUND_BPS", uint256(100));
        if (spread > type(uint16).max) revert InvalidSpread(spread);
        if (bound >= BPS) revert InvalidBound(bound);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 spreadBps = uint16(spread); // Safe after the explicit bound check above.

        vm.startBroadcast(privateKey);
        Vault4626Extruction target = new Vault4626Extruction();
        vm.stopBroadcast();

        (uint256 rate, uint256 shareUnit, address asset) = target.currentRate(vault);
        uint256 minRate = Math.mulDiv(rate, BPS - bound, BPS);
        uint256 maxRate = Math.mulDiv(rate, BPS + bound, BPS, Math.Rounding.Ceil);

        bytes memory currentInstruction =
            AquiferStrategy.buildCurrent(address(target), vault, spreadBps, minRate, maxRate);
        bytes memory v102Instruction = AquiferStrategy.buildV102(address(target), vault, spreadBps, minRate, maxRate);

        console2.log("Vault:", vault);
        console2.log("Asset:", asset);
        console2.log("Share unit:", shareUnit);
        console2.log("Live rate:", rate);
        console2.log("Min rate:", minRate);
        console2.log("Max rate:", maxRate);
        console2.log("Vault4626Extruction:", address(target));
        console2.log("Current-main instruction (opcode 0x04):");
        console2.logBytes(currentInstruction);
        console2.log("Tagged-v1.0.2 instruction (opcode 0x20):");
        console2.logBytes(v102Instruction);
    }
}

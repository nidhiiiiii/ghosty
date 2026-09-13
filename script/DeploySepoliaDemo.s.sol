// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {AquiferStrategy} from "../src/libraries/AquiferStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockERC4626} from "../src/mocks/MockERC4626.sol";

/// @notice Optional public demo deployment. Never use these permissionless mocks for real value.
contract DeploySepoliaDemo is Script {
    uint256 private constant BPS = 10_000;
    uint16 private constant SPREAD_BPS = 15;

    error WrongChain(uint256 actual);
    error TokenOperationFailed();
    error ZeroShares();

    function run() external {
        if (block.chainid != 11_155_111) revert WrongChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 principal = vm.envOr("DEMO_PRINCIPAL", uint256(10_000e6));
        uint256 donatedYield = vm.envOr("DEMO_YIELD", uint256(250e6));

        vm.startBroadcast(privateKey);
        MockERC20 asset = new MockERC20("Aquifer Demo USD", "aqUSD", 6);
        MockERC4626 vault = new MockERC4626(asset, 12);
        Vault4626Extruction target = new Vault4626Extruction();

        asset.mint(deployer, principal + donatedYield);
        if (!asset.approve(address(vault), principal)) revert TokenOperationFailed();
        if (vault.deposit(principal, deployer) == 0) revert ZeroShares();
        if (!asset.transfer(address(vault), donatedYield)) revert TokenOperationFailed();
        vm.stopBroadcast();

        (uint256 rate, uint256 shareUnit,) = target.currentRate(address(vault));
        uint256 minRate = Math.mulDiv(rate, 9_900, BPS);
        uint256 maxRate = Math.mulDiv(rate, 10_100, BPS, Math.Rounding.Ceil);

        console2.log("Mock asset:", address(asset));
        console2.log("Mock vault:", address(vault));
        console2.log("Vault4626Extruction:", address(target));
        console2.log("Share unit:", shareUnit);
        console2.log("Live rate:", rate);
        console2.log("Deployed-router instruction (v1.0.2):");
        console2.logBytes(AquiferStrategy.buildV102(address(target), address(vault), SPREAD_BPS, minRate, maxRate));
        console2.log("Current-main instruction:");
        console2.logBytes(AquiferStrategy.buildCurrent(address(target), address(vault), SPREAD_BPS, minRate, maxRate));
    }
}

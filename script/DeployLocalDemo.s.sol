// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {AquiferStrategy} from "../src/libraries/AquiferStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockERC4626} from "../src/mocks/MockERC4626.sol";

contract DeployLocalDemo is Script {
    uint256 private constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 private constant BPS = 10_000;
    uint16 private constant SPREAD_BPS = 15;

    error TokenOperationFailed();
    error ZeroShares();
    error AssetMismatch(address expected, address actual);

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", ANVIL_PRIVATE_KEY);
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        MockERC20 asset = new MockERC20("Demo USD", "dUSD", 6);
        MockERC4626 vault = new MockERC4626(asset, 12);
        Vault4626Extruction target = new Vault4626Extruction();

        uint256 principal = 1_000_000e6;
        uint256 donatedYield = 50_000e6;
        asset.mint(deployer, principal + donatedYield);
        if (!asset.approve(address(vault), principal)) revert TokenOperationFailed();
        if (vault.deposit(principal, deployer) == 0) revert ZeroShares();
        if (!asset.transfer(address(vault), donatedYield)) revert TokenOperationFailed();
        target.setVaultAllowed(address(vault), true);
        target.setAllowlistEnabled(true);
        vm.stopBroadcast();

        (uint256 rate, uint256 shareUnit, address rateAsset) = target.currentRate(address(vault));
        if (rateAsset != address(asset)) revert AssetMismatch(address(asset), rateAsset);
        uint256 minRate = Math.mulDiv(rate, 9_900, BPS);
        uint256 maxRate = Math.mulDiv(rate, 10_100, BPS, Math.Rounding.Ceil);

        bytes memory deployedInstruction =
            AquiferStrategy.buildDeployed(address(target), address(vault), SPREAD_BPS, minRate, maxRate);

        console2.log("Asset:", address(asset));
        console2.log("Vault:", address(vault));
        console2.log("Vault4626Extruction:", address(target));
        console2.log("Share unit:", shareUnit);
        console2.log("Asset units per share unit:", rate);
        console2.log("Deployed Aqua instruction (opcode 0x20). Do not use 0x04 against the live router.");
        console2.logBytes(deployedInstruction);
    }
}

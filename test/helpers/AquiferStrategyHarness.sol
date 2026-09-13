// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {AquiferStrategy} from "../../src/libraries/AquiferStrategy.sol";

/// @notice External surface for the internal `AquiferStrategy` library so it can be exercised and expect-reverted.
contract AquiferStrategyHarness {
    function opcodeCurrent() external pure returns (uint8) {
        return AquiferStrategy.EXTRUCTION_OPCODE_CURRENT;
    }

    function opcodeV102() external pure returns (uint8) {
        return AquiferStrategy.EXTRUCTION_OPCODE_V102;
    }

    function instructionArgsLength() external pure returns (uint8) {
        return AquiferStrategy.INSTRUCTION_ARGS_LENGTH;
    }

    function encodeConfig(
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) external pure returns (bytes memory) {
        return AquiferStrategy.encodeConfig(vault, spreadBps, minRate, maxRate);
    }

    function buildCurrent(
        address target,
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) external pure returns (bytes memory) {
        return AquiferStrategy.buildCurrent(target, vault, spreadBps, minRate, maxRate);
    }

    function buildV102(
        address target,
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) external pure returns (bytes memory) {
        return AquiferStrategy.buildV102(target, vault, spreadBps, minRate, maxRate);
    }
}

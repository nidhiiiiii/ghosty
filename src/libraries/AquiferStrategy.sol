// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @notice Encodes Aquifer config and the surrounding SwapVM Extruction instruction.
library AquiferStrategy {
    uint8 internal constant EXTRUCTION_OPCODE_CURRENT = 0x04;
    uint8 internal constant EXTRUCTION_OPCODE_V102 = 0x20;
    uint8 internal constant INSTRUCTION_ARGS_LENGTH = 148;

    error InvalidExtructionTarget(address target);

    function encodeConfig(
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal pure returns (bytes memory) {
        return abi.encode(vault, spreadBps, minRate, maxRate);
    }

    /// @notice Builds an instruction for SwapVM current main (four-register ABI).
    function buildCurrent(
        address target,
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal pure returns (bytes memory) {
        return _build(EXTRUCTION_OPCODE_CURRENT, target, encodeConfig(vault, spreadBps, minRate, maxRate));
    }

    /// @notice Builds an instruction for tagged SwapVM v1.0.2 (five-register ABI).
    function buildV102(
        address target,
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal pure returns (bytes memory) {
        return _build(EXTRUCTION_OPCODE_V102, target, encodeConfig(vault, spreadBps, minRate, maxRate));
    }

    /// @notice Instruction for the deployed Aqua router. Same bytes as `buildV102` (opcode 0x20).
    function buildDeployed(
        address target,
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal pure returns (bytes memory) {
        return buildV102(target, vault, spreadBps, minRate, maxRate);
    }

    function _build(
        uint8 opcode,
        address target,
        bytes memory config
    ) private pure returns (bytes memory) {
        if (target == address(0)) revert InvalidExtructionTarget(target);
        return abi.encodePacked(opcode, INSTRUCTION_ARGS_LENGTH, target, config);
    }
}

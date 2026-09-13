// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {AquiferStrategy} from "../src/libraries/AquiferStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AquiferStrategyHarness} from "./helpers/AquiferStrategyHarness.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";
import {RateVault} from "./mocks/MockVaults.sol";

/// @notice SwapVM instruction encoding.
/// @dev Instructions serialise as `opcode(1) || argsLength(1) || args`.
///      The deployed Aqua value is verified against both its router and 1inch swap-vm SDK v0.4.4.
///      The current-main value is verified against `Opcode.Extruction` at SwapVM commit
///      `afd99c408b4ed610027f4426c6f98650acac9f5f`:
///
///          node -e "... new AquaProgramBuilder().add(extruction.createIx(new ExtructionArgs(target, config))).build()"
///          -> 0x20 94 <target> <config>     (AquaSwapVM,  aquaInstructions[32])
///          contracts/libs/OpcodeList.sol
///          -> 0x04 94 <target> <config>     (current SwapVM main enum)
contract AquiferStrategyEncodingTest is AquiferTestBase {
    /// @dev `aquaInstructions.indexOf(extruction)` in @1inch/swap-vm-sdk@0.4.4.
    uint8 internal constant SDK_OPCODE_AQUA = 0x20;
    /// @dev `Opcode.Extruction` in current official SwapVM source.
    uint8 internal constant SOURCE_OPCODE_SWAPVM_MAIN = 0x04;

    AquiferStrategyHarness internal strategy;
    MockERC20 internal usdc;
    RateVault internal vault;

    address internal constant TARGET = address(0x00000000000000000000000000000000000000bb);
    address internal constant CFG_VAULT = address(0x00000000000000000000000000000000000000AA);

    function setUp() public override {
        super.setUp();
        strategy = new AquiferStrategyHarness();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new RateVault(address(usdc), 18, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                          STRUCTURAL INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The length byte is a hardcoded constant; it must stay equal to `20 + CONFIG_LENGTH` or the
    ///      router will slice the wrong number of argument bytes.
    function test_instructionArgsLength_matchesTargetPlusConfig() public view {
        assertEq(
            uint256(strategy.instructionArgsLength()),
            20 + ext.CONFIG_LENGTH(),
            "argsLength byte must equal 20-byte target plus the config length"
        );
    }

    function test_instructionArgsLength_fitsInOneByte() public view {
        assertLe(uint256(strategy.instructionArgsLength()), 255);
    }

    function test_encodedInstruction_totalLengthIs150() public view {
        assertEq(strategy.buildCurrent(TARGET, CFG_VAULT, 15, 900_000, 1_200_000).length, 150);
        assertEq(strategy.buildV102(TARGET, CFG_VAULT, 15, 900_000, 1_200_000).length, 150);
    }

    /// @dev opcode byte, then length byte, then target, then the 128-byte config, with nothing in between.
    function test_encodedInstruction_fieldOffsets() public view {
        bytes memory ix = strategy.buildV102(TARGET, CFG_VAULT, 15, 900_000, 1_200_000);

        assertEq(uint8(ix[1]), strategy.instructionArgsLength(), "byte 1 is the args length");
        assertEq(uint256(uint8(ix[1])), ix.length - 2, "the length byte must describe the remaining bytes");

        address decodedTarget;
        assembly {
            decodedTarget := shr(96, mload(add(ix, 0x22)))
        }
        assertEq(decodedTarget, TARGET, "bytes 2..22 must be the Extruction target");

        bytes memory config_ = new bytes(128);
        for (uint256 i = 0; i < 128; ++i) {
            config_[i] = ix[22 + i];
        }
        (address v, uint16 s, uint256 lo, uint256 hi) = abi.decode(config_, (address, uint16, uint256, uint256));
        assertEq(v, CFG_VAULT);
        assertEq(s, 15);
        assertEq(lo, 900_000);
        assertEq(hi, 1_200_000);
    }

    /// @dev The library's config encoder and the contract's public encoder must agree byte for byte,
    ///      because the frontend uses one and the router feeds the other.
    function testFuzz_libraryAndContractConfigEncodersAgree(
        address v,
        uint16 spread,
        uint256 lo,
        uint256 hi
    ) public view {
        assertEq(
            keccak256(strategy.encodeConfig(v, spread, lo, hi)),
            keccak256(ext.encodeConfig(v, spread, lo, hi)),
            "library and contract config encodings must be identical"
        );
    }

    /// @dev The config slice carved out of a built instruction must be accepted verbatim by the Extruction.
    function test_encodedInstruction_configSliceIsAcceptedByExtruction() public view {
        (uint256 minRate, uint256 maxRate) = bandAround(1_000_000);
        bytes memory ix = strategy.buildV102(TARGET, address(vault), 25, minRate, maxRate);
        bytes memory args = new bytes(128);
        for (uint256 i = 0; i < 128; ++i) {
            args[i] = ix[22 + i];
        }

        Result memory r = quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            args
        );
        // fair = 1_000_000; out = floor(1_000_000 * 9_975 / 10_000) = 997_500
        assertEq(r.amountOut, 997_500, "the instruction's own config bytes must price correctly");
    }

    function test_buildDeployedMatchesV102() public view {
        assertEq(
            keccak256(strategy.buildDeployed(TARGET, CFG_VAULT, 15, 900_000, 1_200_000)),
            keccak256(strategy.buildV102(TARGET, CFG_VAULT, 15, 900_000, 1_200_000))
        );
    }

    function test_buildRejectsZeroTarget() public {
        vm.expectRevert(abi.encodeWithSelector(AquiferStrategy.InvalidExtructionTarget.selector, address(0)));
        strategy.buildCurrent(address(0), CFG_VAULT, 15, 900_000, 1_200_000);

        vm.expectRevert(abi.encodeWithSelector(AquiferStrategy.InvalidExtructionTarget.selector, address(0)));
        strategy.buildV102(address(0), CFG_VAULT, 15, 900_000, 1_200_000);
    }

    /// @dev Both builders must differ only in the leading opcode byte.
    function test_buildersDifferOnlyInOpcodeByte() public view {
        bytes memory a = strategy.buildCurrent(TARGET, CFG_VAULT, 15, 900_000, 1_200_000);
        bytes memory b = strategy.buildV102(TARGET, CFG_VAULT, 15, 900_000, 1_200_000);
        assertEq(a.length, b.length);
        assertTrue(a[0] != b[0], "the two builders must emit different opcodes");
        for (uint256 i = 1; i < a.length; ++i) {
            assertEq(a[i], b[i], "only byte 0 may differ between the builders");
        }
    }

    function testFuzz_encodedInstruction_roundTrips(
        address target,
        address v,
        uint16 spread,
        uint256 lo,
        uint256 hi
    ) public view {
        vm.assume(target != address(0));
        bytes memory ix = strategy.buildCurrent(target, v, spread, lo, hi);
        assertEq(ix.length, 150);
        assertEq(uint256(uint8(ix[1])), 148);

        address decodedTarget;
        assembly {
            decodedTarget := shr(96, mload(add(ix, 0x22)))
        }
        assertEq(decodedTarget, target);

        bytes memory config_ = new bytes(128);
        for (uint256 i = 0; i < 128; ++i) {
            config_[i] = ix[22 + i];
        }
        assertEq(keccak256(config_), keccak256(ext.encodeConfig(v, spread, lo, hi)));
    }

    /*//////////////////////////////////////////////////////////////
                     OPCODE BYTES VS THE ROUTER TABLES
    //////////////////////////////////////////////////////////////*/

    function test_opcodeCurrent_matchesSwapVmMainSource() public view {
        assertEq(
            uint256(strategy.opcodeCurrent()),
            uint256(SOURCE_OPCODE_SWAPVM_MAIN),
            "buildCurrent must emit Opcode.Extruction == 0x04"
        );
    }

    /// @dev `EXTRUCTION_OPCODE_V102 = 0x20` does match the AquaSwapVM table, so this one holds.
    function test_opcodeV102_matchesAquaInstructionTable() public view {
        assertEq(
            uint256(strategy.opcodeV102()),
            uint256(SDK_OPCODE_AQUA),
            "buildV102 must emit aquaInstructions.indexOf(extruction) == 0x20"
        );
    }

    function test_opcodes_areDistinctAcrossLayouts() public view {
        assertTrue(strategy.opcodeCurrent() != strategy.opcodeV102());
    }

    /// @dev Byte-exact fixture captured from the SDK's AquaProgramBuilder.
    function test_encodedInstruction_matchesSdkFixture_aqua() public view {
        bytes memory expected = hex"20" hex"94" hex"00000000000000000000000000000000000000bb"
            hex"00000000000000000000000000000000000000000000000000000000000000aa"
            hex"000000000000000000000000000000000000000000000000000000000000000f"
            hex"00000000000000000000000000000000000000000000000000000000000dbba0"
            hex"0000000000000000000000000000000000000000000000000000000000124f80";
        assertEq(expected.length, 150);
        assertEq(
            keccak256(strategy.buildV102(TARGET, CFG_VAULT, 15, 900_000, 1_200_000)),
            keccak256(expected),
            "buildV102 must reproduce the SDK's AquaProgramBuilder bytes exactly"
        );
    }

    /// @dev Byte-exact fixture for current SwapVM main's enum-based dispatcher.
    function test_encodedInstruction_matchesCurrentSwapVmSource() public view {
        bytes memory expected = hex"04" hex"94" hex"00000000000000000000000000000000000000bb"
            hex"00000000000000000000000000000000000000000000000000000000000000aa"
            hex"000000000000000000000000000000000000000000000000000000000000000f"
            hex"00000000000000000000000000000000000000000000000000000000000dbba0"
            hex"0000000000000000000000000000000000000000000000000000000000124f80";
        assertEq(expected.length, 150);
        assertEq(
            keccak256(strategy.buildCurrent(TARGET, CFG_VAULT, 15, 900_000, 1_200_000)),
            keccak256(expected),
            "buildCurrent must reproduce the current source's enum opcode exactly"
        );
    }
}

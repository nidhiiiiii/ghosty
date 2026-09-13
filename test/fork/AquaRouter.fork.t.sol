// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {Vault4626Extruction} from "../../src/Vault4626Extruction.sol";
import {
    IExtruction,
    IExtructionV102,
    SwapQuery,
    SwapRegisters,
    SwapRegistersV102
} from "../../src/interfaces/ISwapVMExtruction.sol";
import {AquiferStrategy} from "../../src/libraries/AquiferStrategy.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockERC4626} from "../../src/mocks/MockERC4626.sol";

/// @notice Reverts with whatever the router handed it, so the router's real Extruction ABI can be read off.
contract ExtructionProbe {
    /// @dev A 32-byte magic makes the payload findable inside whatever the router wraps it in, without
    ///      the false positives a 4-byte selector would hit against zero padding.
    bytes32 public constant MAGIC = keccak256("aquifer.extruction.probe");

    error ProbeCalldata(bytes32 magic, bytes data);

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        revert ProbeCalldata(MAGIC, data);
    }
}

/// @notice Validates the Extruction interface, register layout and instruction opcode against the
///         *deployed* AquaSwapVM router rather than against a hand-written interface file.
/// @dev Requires a mainnet RPC. Set `MAINNET_RPC_URL` (or leave the default local anvil fork running).
///      The suite skips itself when no fork is reachable so CI without an RPC stays green.
contract AquaRouterForkTest is Test {
    /// @dev `struct ISwapVM.Order` as declared by the deployed router's ABI.
    struct Order {
        address maker;
        uint256 traits;
        bytes data;
    }

    /// @dev `AQUA_SWAP_VM_CONTRACT_ADDRESSES[1]` from @1inch/swap-vm-sdk@0.4.4.
    address internal constant AQUA_SWAP_VM = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev `quote((address,uint256,bytes),address,address,uint256,bytes)`.
    bytes4 internal constant QUOTE_SELECTOR = 0x44aa5f14;

    /// @dev MakerTraits with `useAquaInsteadOfSignature = true`, no receiver and no hooks.
    uint256 internal constant MAKER_TRAITS_AQUA = 0x4000000000000000000000000000000000000000000000000000000000000000;
    /// @dev MakerTraits with every flag clear (signature-authenticated order).
    uint256 internal constant MAKER_TRAITS_SIGNED = 0;

    /// @dev `AQUA_CONTRACT_ADDRESSES[1]` from @1inch/aqua-sdk@0.3.4.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @dev `safeBalances(address,address,bytes32,address,address) returns (uint256,uint256)`.
    bytes4 internal constant SAFE_BALANCES_SELECTOR = 0x65f2fe14;

    /// @dev TakerTraits: exactIn, firstTransferFromTaker, no threshold, no hooks.
    bytes internal constant TAKER_TRAITS_EXACT_IN = hex"00000000000000000000000000000000000000000021";
    /// @dev TakerTraits: exactOut, firstTransferFromTaker, no threshold, no hooks.
    bytes internal constant TAKER_TRAITS_EXACT_OUT = hex"00000000000000000000000000000000000000000020";

    bool internal forked;

    MockERC20 internal asset;
    MockERC4626 internal vault;
    Vault4626Extruction internal ext;
    ExtructionProbe internal probe;

    address internal maker = makeAddr("forkMaker");
    address internal taker = makeAddr("forkTaker");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("http://127.0.0.1:18546"));
        try vm.createSelectFork(rpc) {
            forked = AQUA_SWAP_VM.code.length > 0;
        } catch {
            forked = false;
        }
        if (!forked) return;

        asset = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(IERC20(address(asset)), 0);
        ext = new Vault4626Extruction();
        probe = new ExtructionProbe();

        asset.mint(maker, 1_000_000e6);
        vm.startPrank(maker);
        asset.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, maker);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _skipIfNoFork() internal {
        if (!forked) vm.skip(true);
    }

    /// @notice Stands in for a maker who has already shipped and funded an Aqua strategy.
    /// @dev Only Aqua's balance bookkeeping is mocked. The router, its opcode table, its program
    ///      decoder and the Extruction call itself all run for real.
    function _mockAquaBalances(
        uint256 balanceIn,
        uint256 balanceOut
    ) internal {
        vm.mockCall(AQUA, abi.encodeWithSelector(SAFE_BALANCES_SELECTOR), abi.encode(balanceIn, balanceOut));
    }

    function _bandAround(
        uint256 rate
    ) internal pure returns (uint256 minRate, uint256 maxRate) {
        minRate = rate * 9_900 / 10_000;
        maxRate = rate + (rate * 100 + 9_999) / 10_000;
    }

    function _program(
        uint8 opcode,
        address target
    ) internal view returns (bytes memory) {
        (uint256 minRate, uint256 maxRate) = _bandAround(1e6);
        bytes memory config = ext.encodeConfig(address(vault), 15, minRate, maxRate);
        return abi.encodePacked(opcode, uint8(148), target, config);
    }

    /// @notice Calls the deployed router's `quote` and hands back raw success/returndata.
    function _routerQuote(
        bytes memory program,
        uint256 makerTraits,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerTraits
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory callData = abi.encodeWithSelector(
            QUOTE_SELECTOR, Order(maker, makerTraits, program), tokenIn, tokenOut, amount, takerTraits
        );
        vm.prank(taker);
        (ok, ret) = AQUA_SWAP_VM.call(callData);
    }

    /// @dev Pulls the probe's captured calldata out of returndata, wherever the router nested it.
    ///      `ProbeCalldata(bytes32,bytes)` encodes as magic || offset(0x40) || length || data.
    function _extractProbeCalldata(
        bytes memory ret
    ) internal pure returns (bool found, bytes memory inner) {
        bytes32 magic = keccak256("aquifer.extruction.probe");
        if (ret.length < 96) return (false, "");
        for (uint256 i = 0; i + 96 <= ret.length; ++i) {
            bytes32 word;
            uint256 offsetWord;
            uint256 lengthWord;
            assembly {
                let base := add(add(ret, 0x20), i)
                word := mload(base)
                offsetWord := mload(add(base, 0x20))
                lengthWord := mload(add(base, 0x40))
            }
            if (word != magic) continue;
            if (offsetWord != 0x40) continue;
            if (i + 96 + lengthWord > ret.length) continue;

            inner = new bytes(lengthWord);
            for (uint256 j = 0; j < lengthWord; ++j) {
                inner[j] = ret[i + 96 + j];
            }
            return (true, inner);
        }
        return (false, "");
    }

    function _selectorOf(
        bytes memory data
    ) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "no selector");
        sel = bytes4(bytes.concat(data[0], data[1], data[2], data[3]));
    }

    function _stripSelector(
        bytes memory data
    ) internal pure returns (bytes memory body) {
        body = new bytes(data.length - 4);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = data[i + 4];
        }
    }

    /*//////////////////////////////////////////////////////////////
                     WHICH OPCODE ACTUALLY DISPATCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice The deployed router must dispatch `AquiferStrategy.EXTRUCTION_OPCODE_V102` (0x20) to the
    ///         Extruction target. Proven by the target being reached at all.
    function test_fork_opcode0x20ReachesTheExtructionTarget() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_V102, address(probe)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );
        assertFalse(ok, "the probe always reverts");
        (bool found,) = _extractProbeCalldata(ret);
        if (!found) {
            console2.log("router returndata for opcode 0x20:");
            console2.logBytes(ret);
        }
        assertTrue(found, "opcode 0x20 must dispatch to the Extruction target");
    }

    /// @notice Current SwapVM main uses 0x04, but the deployed v1.0.2 Aqua router has a different table.
    function test_fork_opcode0x04NeverReachesTheExtructionTarget() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_CURRENT, address(probe)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );
        assertFalse(ok, "an unregistered opcode cannot produce a quote");
        (bool found,) = _extractProbeCalldata(ret);
        console2.log("router returndata for opcode 0x04:");
        console2.logBytes(ret);
        assertFalse(found, "opcode 0x04 must not reach the Extruction target");
    }

    /// @notice The legacy SDK regular table uses 0x21, but on the deployed Aqua router index 33 is
    ///         `onlyTxOriginTokenBalanceNonZero`. Opcode bytes are router-version-specific.
    function test_fork_opcode0x21IsNotExtructionOnTheAquaRouter() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(0x21, address(probe)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );
        assertFalse(ok, "0x21 is not extruction on the Aqua router, so this program cannot quote");

        (bool found, bytes memory inner) = _extractProbeCalldata(ret);
        console2.log("calldata the Aqua router sent to the target under opcode 0x21:");
        console2.logBytes(inner);

        // `aquaInstructions[33]` is `onlyTxOriginTokenBalanceNonZero`, which reads the first 20 argument
        // bytes as a *token* and calls `balanceOf(tx.origin)` on it.
        assertTrue(found, "the target is still reached, just not as an Extruction");
        bytes4 sel = _selectorOf(inner);
        assertEq(bytes32(sel), bytes32(IERC20.balanceOf.selector), "0x21 treats the target as an ERC-20 token");
        assertTrue(sel != IExtruction.extruction.selector, "0x21 must not invoke the four-register Extruction");
        assertTrue(sel != IExtructionV102.extruction.selector, "0x21 must not invoke the five-register Extruction");
    }

    /*//////////////////////////////////////////////////////////////
                    THE ROUTER'S REAL EXTRUCTION ABI
    //////////////////////////////////////////////////////////////*/

    /// @notice Reads the exact calldata the deployed router sends to an Extruction target and asserts it
    ///         matches one of the two interfaces in `ISwapVMExtruction.sol`, with the fields in the
    ///         positions the implementation reads them from.
    function test_fork_routerCalldataMatchesDeclaredInterface() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_V102, address(probe)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );
        (bool found, bytes memory inner) = _extractProbeCalldata(ret);
        assertTrue(found, "the probe must have been reached");

        bytes4 sel = _selectorOf(inner);
        console2.log("extruction selector used by the deployed router:");
        console2.logBytes32(bytes32(sel));
        console2.log("ISwapVMExtruction current (4 registers):");
        console2.logBytes32(bytes32(IExtruction.extruction.selector));
        console2.log("ISwapVMExtruction v1.0.2 (5 registers):");
        console2.logBytes32(bytes32(IExtructionV102.extruction.selector));
        console2.log("full calldata length:", inner.length);
        console2.logBytes(inner);

        bool isCurrent = sel == IExtruction.extruction.selector;
        bool isV102 = sel == IExtructionV102.extruction.selector;
        assertTrue(
            isCurrent || isV102,
            "the deployed router's Extruction selector must match a declared interface in ISwapVMExtruction.sol"
        );
        assertTrue(
            isV102,
            "the deployed Aqua router uses the five-register (v1.0.2) layout; the four-register entry point is dead there"
        );

        (uint256 minRate, uint256 maxRate) = _bandAround(1e6);
        bytes memory expectedArgs = ext.encodeConfig(address(vault), 15, minRate, maxRate);
        bytes memory body = _stripSelector(inner);

        if (isV102) {
            (
                bool isStaticContext,
                uint256 nextPC,
                SwapQuery memory q,
                SwapRegistersV102 memory r,
                bytes memory args,
                bytes memory takerData
            ) = abi.decode(body, (bool, uint256, SwapQuery, SwapRegistersV102, bytes, bytes));
            assertTrue(isStaticContext, "the quote path must arrive with isStaticContext set");
            assertEq(takerData.length, 0, "no takerData was supplied, so none must be forwarded");
            _assertQuery(q);
            assertEq(keccak256(args), keccak256(expectedArgs), "the router must forward the config verbatim");
            assertEq(r.amountIn, 100e6, "the exact-in amount must land in the amountIn register");
            assertEq(r.amountOut, 0, "the unspecified register must arrive zeroed");
            console2.log("nextPC:", nextPC);
            console2.log("balanceIn:", r.balanceIn);
            console2.log("balanceOut:", r.balanceOut);
            console2.log("amountNetPulled:", r.amountNetPulled);
        } else {
            (, uint256 nextPC, SwapQuery memory q, SwapRegisters memory r, bytes memory args,) =
                abi.decode(body, (bool, uint256, SwapQuery, SwapRegisters, bytes, bytes));
            _assertQuery(q);
            assertEq(keccak256(args), keccak256(expectedArgs), "the router must forward the config verbatim");
            assertEq(r.amountIn, 100e6, "the exact-in amount must land in the amountIn register");
            assertEq(r.amountOut, 0, "the unspecified register must arrive zeroed");
            console2.log("nextPC:", nextPC);
            console2.log("balanceIn:", r.balanceIn);
            console2.log("balanceOut:", r.balanceOut);
        }
    }

    function _assertQuery(
        SwapQuery memory q
    ) internal view {
        assertEq(q.maker, maker, "SwapQuery.maker must decode to the order's maker");
        assertEq(q.taker, taker, "SwapQuery.taker must decode to the caller");
        assertEq(q.tokenIn, address(vault), "SwapQuery.tokenIn must decode to the share token");
        assertEq(q.tokenOut, address(asset), "SwapQuery.tokenOut must decode to the asset token");
        assertTrue(q.isExactIn, "SwapQuery.isExactIn must decode to the taker's exact-in flag");
    }

    /*//////////////////////////////////////////////////////////////
                  END-TO-END THROUGH THE REAL EXTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice With the real implementation behind the opcode, the router-driven quote must produce the
    ///         same numbers the implementation produces when called directly.
    function test_fork_realExtructionPricesThroughTheRouter() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_V102, address(ext)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );

        // fair = 100e6 at rate 1e6/1e6; out = floor(100e6 * 9_985 / 10_000) = 99_850_000
        if (ok) {
            (uint256 amountIn, uint256 amountOut,) = abi.decode(ret, (uint256, uint256, bytes32));
            assertEq(amountIn, 100e6, "the router must report the taker's exact-in amount");
            assertEq(amountOut, 99_850_000, "the router-driven quote must match the direct quote");
        } else {
            // A maker with no Aqua balance cannot back the quote; the Extruction must be the thing that
            // says so, with the amount it computed.
            console2.log("router returndata with the real Extruction:");
            console2.logBytes(ret);
            assertEq(
                bytes32(_selectorOf(ret)),
                bytes32(Vault4626Extruction.InsufficientLiquidity.selector),
                "the only acceptable failure here is the Extruction's own liquidity guard"
            );
            (uint256 requested, uint256 available) = abi.decode(_stripSelector(ret), (uint256, uint256));
            assertEq(requested, 99_850_000, "the Extruction must have priced the leg before refusing it");
            assertEq(available, 0, "balanceOut must be zero for a maker with no Aqua balance");
        }
    }

    /// @notice The exact-out leg must survive the round trip through the real router too.
    function test_fork_realExtructionExactOutThroughTheRouter() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 1_000_000e6);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_V102, address(ext)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            99_850_000,
            TAKER_TRAITS_EXACT_OUT
        );
        if (!ok) {
            console2.log("exact-out router returndata:");
            console2.logBytes(ret);
        }
        assertTrue(ok, "an exact-out quote must succeed against the deployed router");

        (uint256 amountIn, uint256 amountOut,) = abi.decode(ret, (uint256, uint256, bytes32));
        // keptBps = 9_985; fair = ceil(99_850_000 * 10_000 / 9_985) = 100_000_000; in = ceil(100e6 * 1e6 / 1e6)
        assertEq(amountOut, 99_850_000, "the router must report the taker's exact-out amount");
        assertEq(amountIn, 100e6, "exact-out must be the exact inverse of the exact-in leg");
    }

    /// @notice The maker's real Aqua balance is what lands in `balanceOut`, so the liquidity guard is
    ///         meaningful rather than decorative.
    function test_fork_balanceOutRegisterDrivesTheLiquidityGuard() public {
        _skipIfNoFork();
        _mockAquaBalances(1_000_000e6, 99_849_999);
        (bool ok, bytes memory ret) = _routerQuote(
            _program(AquiferStrategy.EXTRUCTION_OPCODE_V102, address(ext)),
            MAKER_TRAITS_AQUA,
            address(vault),
            address(asset),
            100e6,
            TAKER_TRAITS_EXACT_IN
        );
        assertFalse(ok, "a quote larger than the maker's Aqua balance must be refused");
        assertEq(
            bytes32(_selectorOf(ret)),
            bytes32(Vault4626Extruction.InsufficientLiquidity.selector),
            "the Extruction must be the one to refuse it"
        );
        (uint256 requested, uint256 available) = abi.decode(_stripSelector(ret), (uint256, uint256));
        assertEq(requested, 99_850_000);
        assertEq(available, 99_849_999, "the router must forward the maker's Aqua balance as balanceOut");
    }
}

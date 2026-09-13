// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {
    IExtruction,
    IExtructionV102,
    IStaticExtruction,
    IStaticExtructionV102,
    SwapRegisters,
    SwapRegistersV102
} from "../src/interfaces/ISwapVMExtruction.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";
import {RateVault} from "./mocks/MockVaults.sol";

/// @notice Register-layout coverage: current four-register main ABI and tagged v1.0.2 five-register ABI,
///         plus quote/swap determinism across STATICCALL and CALL.
contract Vault4626ExtructionLayoutsTest is AquiferTestBase {
    MockERC20 internal usdc;
    RateVault internal vault;

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new RateVault(address(usdc), 18, 1_050_000);
    }

    function _cfg() internal view returns (bytes memory) {
        return config(address(vault), 15, 900_000, 1_200_000);
    }

    /*//////////////////////////////////////////////////////////////
                        DISTINCT ABI ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The two layouts must be reachable as separate selectors; a collision would make one
    ///      unreachable from the router.
    function test_selectors_areDistinct() public pure {
        bytes4 current = IExtruction.extruction.selector;
        bytes4 v102 = IExtructionV102.extruction.selector;
        assertTrue(current != v102, "the two register layouts must not share a selector");
        assertEq(
            bytes32(current), bytes32(IStaticExtruction.extruction.selector), "quote and swap must share one selector"
        );
        assertEq(
            bytes32(v102), bytes32(IStaticExtructionV102.extruction.selector), "quote and swap must share one selector"
        );
    }

    /// @dev Both entry points must actually be dispatched by the deployed bytecode.
    function test_bothEntryPointsAreDispatched() public view {
        Result memory a =
            quoteCurrent(query(address(vault), address(usdc), true), registers(true, 1e18, 5e18, 10_000_000), _cfg());
        Result memory b = quoteV102(
            query(address(vault), address(usdc), true), registersV102(true, 1e18, 5e18, 10_000_000, 0), _cfg()
        );
        assertEq(a.amountOut, 1_048_425);
        assertEq(b.amountOut, 1_048_425);
    }

    /*//////////////////////////////////////////////////////////////
                              LAYOUT PARITY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_layoutParity_sameAmountsBothLayouts(
        bool sharesIn,
        bool isExactIn,
        uint64 specified,
        uint16 spreadRaw,
        uint64 netPulled
    ) public view {
        uint256 amount = bound(uint256(specified), 1e18, type(uint64).max);
        uint16 spread = spreadRaw % 10_000;
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        Result memory a = quoteCurrent(
            query(tokenIn, tokenOut, isExactIn),
            registers(isExactIn, amount, type(uint256).max, type(uint256).max),
            config(address(vault), spread, 900_000, 1_200_000)
        );
        Result memory b = quoteV102(
            query(tokenIn, tokenOut, isExactIn),
            registersV102(isExactIn, amount, type(uint256).max, type(uint256).max, netPulled),
            config(address(vault), spread, 900_000, 1_200_000)
        );

        assertEq(a.amountIn, b.amountIn, "amountIn must match across layouts");
        assertEq(a.amountOut, b.amountOut, "amountOut must match across layouts");
        assertEq(a.nextPC, b.nextPC);
        assertEq(a.choppedLength, b.choppedLength);
        assertEq(b.amountNetPulled, netPulled, "v1.0.2 fee register must pass through untouched");
    }

    function test_v102_preservesAmountNetPulled() public view {
        Result memory r = quoteV102(
            query(address(vault), address(usdc), true), registersV102(true, 1e18, 123, 10_000_000, 987_654_321), _cfg()
        );
        assertEq(r.amountNetPulled, 987_654_321);
        assertEq(r.balanceIn, 123);
        assertEq(r.balanceOut, 10_000_000);
    }

    function test_v102_balanceRegistersUntouched() public view {
        Result memory r = quoteV102(
            query(address(usdc), address(vault), false), registersV102(false, 5e17, 4_444, 1e18, 9_999), _cfg()
        );
        assertRegistersUntouched(r, 4_444, 1e18);
        assertEq(r.amountNetPulled, 9_999);
    }

    function test_current_balanceRegistersUntouched() public view {
        Result memory r =
            quoteCurrent(query(address(usdc), address(vault), false), registers(false, 5e17, 4_444, 1e18), _cfg());
        assertRegistersUntouched(r, 4_444, 1e18);
    }

    /// @dev nextPC must be echoed for any value the VM might pass.
    function testFuzz_nextPCIsEchoed(
        uint256 pc
    ) public view {
        (uint256 updatedPC, uint256 chopped,) = IStaticExtruction(address(ext))
            .extruction(
                true,
                pc,
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                _cfg(),
                ""
            );
        assertEq(updatedPC, pc);
        assertEq(chopped, 0);
    }

    /// @dev takerData is declared but unused; supplying any payload must not change the quote.
    function testFuzz_takerDataIsIgnored(
        bytes calldata takerData
    ) public view {
        (,, SwapRegisters memory withData) = IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                _cfg(),
                takerData
            );
        assertEq(withData.amountOut, 1_048_425, "takerData must not influence pricing");
    }

    /// @dev isStaticContext is declared but unused; both values must produce the same quote.
    function test_isStaticContextFlagIsIgnored() public view {
        (,, SwapRegisters memory asStatic) = IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                _cfg(),
                ""
            );
        (,, SwapRegisters memory asSwap) = IStaticExtruction(address(ext))
            .extruction(
                false,
                DEFAULT_PC,
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                _cfg(),
                ""
            );
        assertEq(asStatic.amountOut, asSwap.amountOut);
        assertEq(asStatic.amountIn, asSwap.amountIn);
    }

    /*//////////////////////////////////////////////////////////////
                       QUOTE / SWAP DETERMINISM
    //////////////////////////////////////////////////////////////*/

    /// @dev The whole design rests on quote (STATICCALL) and swap (CALL) being the same code path.
    function testFuzz_quoteEqualsSwap_current(
        bool sharesIn,
        bool isExactIn,
        uint64 specified,
        uint16 spreadRaw
    ) public {
        uint256 amount = bound(uint256(specified), 1e18, type(uint64).max);
        uint16 spread = spreadRaw % 10_000;
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        Result memory quoted = quoteCurrent(
            query(tokenIn, tokenOut, isExactIn),
            registers(isExactIn, amount, type(uint256).max, type(uint256).max),
            config(address(vault), spread, 900_000, 1_200_000)
        );
        Result memory filled = swapCurrent(
            query(tokenIn, tokenOut, isExactIn),
            registers(isExactIn, amount, type(uint256).max, type(uint256).max),
            config(address(vault), spread, 900_000, 1_200_000)
        );

        assertEq(quoted.amountIn, filled.amountIn, "quote and swap amountIn must be identical");
        assertEq(quoted.amountOut, filled.amountOut, "quote and swap amountOut must be identical");
    }

    function testFuzz_quoteEqualsSwap_v102(
        bool sharesIn,
        bool isExactIn,
        uint64 specified,
        uint16 spreadRaw
    ) public {
        uint256 amount = bound(uint256(specified), 1e18, type(uint64).max);
        uint16 spread = spreadRaw % 10_000;
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        Result memory quoted = quoteV102(
            query(tokenIn, tokenOut, isExactIn),
            registersV102(isExactIn, amount, type(uint256).max, type(uint256).max, 42),
            config(address(vault), spread, 900_000, 1_200_000)
        );
        Result memory filled = swapV102(
            query(tokenIn, tokenOut, isExactIn),
            registersV102(isExactIn, amount, type(uint256).max, type(uint256).max, 42),
            config(address(vault), spread, 900_000, 1_200_000)
        );

        assertEq(quoted.amountIn, filled.amountIn);
        assertEq(quoted.amountOut, filled.amountOut);
        assertEq(quoted.amountNetPulled, filled.amountNetPulled);
    }

    /// @dev Repeated calls in the same block must be byte-identical: no hidden nonce or cached state.
    function test_repeatedCallsAreIdempotent() public {
        for (uint256 i = 0; i < 3; ++i) {
            Result memory r = swapCurrent(
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                _cfg()
            );
            assertEq(r.amountOut, 1_048_425);
        }
    }

    /// @dev The swap path must not mutate the Extruction's own storage or the vault's.
    function test_swapPathIsSideEffectFree() public {
        uint256 snapshot = vm.snapshotState();
        bytes32 extSlot0Before = vm.load(address(ext), bytes32(0));

        vm.recordLogs();
        swapCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            _cfg()
        );
        assertEq(vm.getRecordedLogs().length, 0, "the Extruction must emit no events");
        assertEq(vm.load(address(ext), bytes32(0)), extSlot0Before, "the Extruction must write no storage");
        assertEq(vault.ratePerShareUnit(), 1_050_000, "the vault must be read-only from the Extruction");

        vm.revertToState(snapshot);
    }

    /// @dev A rate change between quote and fill is reflected, which is the documented reason bounds exist.
    function test_rateDriftBetweenQuoteAndFillIsReflected() public {
        Result memory before = quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            _cfg()
        );
        assertEq(before.amountOut, 1_048_425);

        vault.setRate(1_100_000);
        Result memory after_ = swapCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            _cfg()
        );
        // fair = 1_100_000; out = floor(1_100_000 * 9_985 / 10_000) = 1_098_350
        assertEq(after_.amountOut, 1_098_350);
        assertGt(after_.amountOut, before.amountOut);
    }

    /// @dev Once drift leaves the configured band, both paths must refuse identically.
    function test_rateDriftOutOfBandRevertsOnBothPaths() public {
        vault.setRate(1_200_001);
        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, 1_200_001, 900_000, 1_200_000)
        );
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            _cfg()
        );

        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, 1_200_001, 900_000, 1_200_000)
        );
        swapCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            _cfg()
        );
    }
}

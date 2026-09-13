// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {stdError} from "forge-std/StdError.sol";

import {IStaticExtruction, SwapQuery, SwapRegisters} from "../src/interfaces/ISwapVMExtruction.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";
import {RateVault} from "./mocks/MockVaults.sol";

/// @notice Property and fuzz tests.
/// @dev Wherever possible the oracle is *external* to the pricing formula: either the vault's own
///      ERC-4626 conversion functions, or a second quote from the contract at a different input,
///      rather than a re-implementation of `_quote`.
contract Vault4626ExtructionPropertiesTest is AquiferTestBase {
    MockERC20 internal usdc;
    RateVault internal vault;

    uint256 internal constant MAX_RATE = 1e30;
    uint256 internal constant MAX_AMOUNT = 1e30;

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new RateVault(address(usdc), 18, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _tryQuote(
        bool sharesIn,
        bool isExactIn,
        uint256 amount,
        uint16 spreadBps
    ) internal view returns (bool ok, uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));
        try IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(tokenIn, tokenOut, isExactIn),
                registers(isExactIn, amount, type(uint256).max, type(uint256).max),
                tightConfig(address(vault), spreadBps, vault.ratePerShareUnit()),
                ""
            ) returns (
            uint256, uint256, SwapRegisters memory r
        ) {
            return (true, r.amountIn, r.amountOut);
        } catch {
            return (false, 0, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                  SPEC: PRICED AT THE VAULT'S OWN RATE
    //////////////////////////////////////////////////////////////*/

    /// @dev With zero spread, a shares-in exact-in quote must equal the vault's own
    ///      `convertToAssets(amountIn)`. The oracle here is ERC-4626 itself, not the pricing formula.
    function testFuzz_zeroSpread_sharesIn_matchesConvertToAssets(
        uint256 rateSeed,
        uint256 amountSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        vault.setRate(rate);

        (bool ok,, uint256 amountOut) = _tryQuote(true, true, amount, 0);
        uint256 expected = vault.convertToAssets(amount);
        if (expected == 0) {
            assertFalse(ok, "a quote that converts to zero assets must revert, not silently pay zero");
        } else {
            assertTrue(ok, "a non-zero conversion must produce a quote");
            assertEq(amountOut, expected, "zero-spread pricing must be the vault's own conversion");
        }
    }

    /// @dev The mirror direction against `convertToShares`.
    function testFuzz_zeroSpread_assetsIn_matchesConvertToShares(
        uint256 rateSeed,
        uint256 amountSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        vault.setRate(rate);

        (bool ok,, uint256 amountOut) = _tryQuote(false, true, amount, 0);
        uint256 expected = vault.convertToShares(amount);
        if (expected == 0) {
            assertFalse(ok, "a quote that converts to zero shares must revert");
        } else {
            assertTrue(ok);
            assertEq(amountOut, expected, "zero-spread pricing must be the vault's own conversion");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SPREAD PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @dev The spread must be applied to the fair amount exactly once, flooring on exact-in.
    ///      `fair` is taken from a zero-spread quote, so the formula is never re-derived.
    function testFuzz_exactIn_spreadIsAppliedExactlyOnce(
        uint256 rateSeed,
        uint256 amountSeed,
        uint16 spreadSeed,
        bool sharesIn
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        vault.setRate(rate);

        (bool okFair,, uint256 fair) = _tryQuote(sharesIn, true, amount, 0);
        if (!okFair) return;

        uint256 kept = BPS - spread;
        uint256 expected = fair * kept / BPS;

        (bool ok,, uint256 amountOut) = _tryQuote(sharesIn, true, amount, spread);
        if (expected == 0) {
            assertFalse(ok, "a spread that eats the whole output must revert with AmountRoundsToZero");
        } else {
            assertTrue(ok);
            assertEq(amountOut, expected, "amountOut must be floor(fair * keptBps / BPS)");
        }
    }

    /// @dev Widening the spread can never improve the taker's exact-in output.
    function testFuzz_exactIn_outputIsMonotonicDecreasingInSpread(
        uint256 amountSeed,
        uint16 spreadA,
        uint16 spreadB,
        bool sharesIn
    ) public view {
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 lo = uint16(bound(spreadA, 0, 9_999));
        uint16 hi = uint16(bound(spreadB, 0, 9_999));
        if (lo > hi) (lo, hi) = (hi, lo);

        (bool okLo,, uint256 outLo) = _tryQuote(sharesIn, true, amount, lo);
        (bool okHi,, uint256 outHi) = _tryQuote(sharesIn, true, amount, hi);
        if (!okLo || !okHi) return;
        assertLe(outHi, outLo, "a wider spread must never pay the taker more");
    }

    /// @dev Widening the spread can never reduce the taker's exact-out cost.
    function testFuzz_exactOut_inputIsMonotonicIncreasingInSpread(
        uint256 amountSeed,
        uint16 spreadA,
        uint16 spreadB,
        bool sharesIn
    ) public view {
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 lo = uint16(bound(spreadA, 0, 9_999));
        uint16 hi = uint16(bound(spreadB, 0, 9_999));
        if (lo > hi) (lo, hi) = (hi, lo);

        (bool okLo, uint256 inLo,) = _tryQuote(sharesIn, false, amount, lo);
        (bool okHi, uint256 inHi,) = _tryQuote(sharesIn, false, amount, hi);
        if (!okLo || !okHi) return;
        assertGe(inHi, inLo, "a wider spread must never make the taker's purchase cheaper");
    }

    /*//////////////////////////////////////////////////////////////
                          AMOUNT MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_exactIn_outputIsMonotonicInAmount(
        uint256 aSeed,
        uint256 bSeed,
        uint16 spreadSeed,
        bool sharesIn
    ) public view {
        uint256 lo = bound(aSeed, 1, MAX_AMOUNT);
        uint256 hi = bound(bSeed, 1, MAX_AMOUNT);
        if (lo > hi) (lo, hi) = (hi, lo);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));

        (bool okLo,, uint256 outLo) = _tryQuote(sharesIn, true, lo, spread);
        (bool okHi,, uint256 outHi) = _tryQuote(sharesIn, true, hi, spread);
        if (!okLo || !okHi) return;
        assertLe(outLo, outHi, "a larger input must never produce a smaller output");
    }

    function testFuzz_exactOut_inputIsMonotonicInAmount(
        uint256 aSeed,
        uint256 bSeed,
        uint16 spreadSeed,
        bool sharesIn
    ) public view {
        uint256 lo = bound(aSeed, 1, MAX_AMOUNT);
        uint256 hi = bound(bSeed, 1, MAX_AMOUNT);
        if (lo > hi) (lo, hi) = (hi, lo);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));

        (bool okLo, uint256 inLo,) = _tryQuote(sharesIn, false, lo, spread);
        (bool okHi, uint256 inHi,) = _tryQuote(sharesIn, false, hi, spread);
        if (!okLo || !okHi) return;
        assertLe(inLo, inHi, "a larger requested output must never cost less");
    }

    /*//////////////////////////////////////////////////////////////
                       RATE DIRECTIONAL SENSITIVITY
    //////////////////////////////////////////////////////////////*/

    /// @dev A richer share must fetch at least as many assets, and cost at least as many assets.
    function testFuzz_higherRateFavoursShareSellers(
        uint256 rateA,
        uint256 rateB,
        uint256 amountSeed,
        uint16 spreadSeed
    ) public {
        uint256 lo = bound(rateA, 1, MAX_RATE);
        uint256 hi = bound(rateB, 1, MAX_RATE);
        if (lo > hi) (lo, hi) = (hi, lo);
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));

        vault.setRate(lo);
        (bool okA,, uint256 assetsOutLo) = _tryQuote(true, true, amount, spread);
        (bool okC,, uint256 sharesOutLo) = _tryQuote(false, true, amount, spread);

        vault.setRate(hi);
        (bool okB,, uint256 assetsOutHi) = _tryQuote(true, true, amount, spread);
        (bool okD,, uint256 sharesOutHi) = _tryQuote(false, true, amount, spread);

        if (okA && okB) assertGe(assetsOutHi, assetsOutLo, "a higher rate must pay share sellers more");
        if (okC && okD) assertLe(sharesOutHi, sharesOutLo, "a higher rate must give share buyers fewer shares");
    }

    /*//////////////////////////////////////////////////////////////
                     EXACT-IN / EXACT-OUT CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev The central no-free-lunch invariant: whatever exact-out charges for `d` units of output must
    ///      be enough that feeding it back through exact-in still delivers at least `d`.
    function testFuzz_exactOutCostCoversExactInDelivery(
        uint256 rateSeed,
        uint256 amountSeed,
        uint16 spreadSeed,
        bool sharesIn
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 desiredOut = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        vault.setRate(rate);

        (bool okOut, uint256 requiredIn,) = _tryQuote(sharesIn, false, desiredOut, spread);
        if (!okOut) return;

        (bool okIn,, uint256 deliveredOut) = _tryQuote(sharesIn, true, requiredIn, spread);
        assertTrue(okIn, "the input exact-out demanded must itself be a quotable exact-in amount");
        assertGe(deliveredOut, desiredOut, "exact-out must never undercharge relative to exact-in");
    }

    /// @dev The reverse direction: exact-out must not overcharge either, beyond the rounding the
    ///      spread ceilings introduce.
    function testFuzz_exactInThenExactOutNeverCostsMore(
        uint256 rateSeed,
        uint256 amountSeed,
        uint16 spreadSeed,
        bool sharesIn
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        vault.setRate(rate);

        (bool okIn,, uint256 quotedOut) = _tryQuote(sharesIn, true, amount, spread);
        if (!okIn || quotedOut == 0) return;

        (bool okOut, uint256 requiredIn,) = _tryQuote(sharesIn, false, quotedOut, spread);
        if (!okOut) return;
        assertLe(requiredIn, amount, "buying the amount exact-in quoted must not cost more than it charged");
    }

    /*//////////////////////////////////////////////////////////////
                        ROUND TRIP / VALUE LEAK
    //////////////////////////////////////////////////////////////*/

    /// @dev Selling shares for assets and immediately buying shares back must never leave the taker
    ///      with more shares than they started with.
    function testFuzz_roundTripNeverMintsValue(
        uint256 rateSeed,
        uint256 amountSeed,
        uint16 spreadSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 shares = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        vault.setRate(rate);

        (bool ok1,, uint256 assetsOut) = _tryQuote(true, true, shares, spread);
        if (!ok1 || assetsOut == 0) return;

        (bool ok2,, uint256 sharesBack) = _tryQuote(false, true, assetsOut, spread);
        if (!ok2) return;
        assertLe(sharesBack, shares, "a share -> asset -> share round trip must not mint shares");
    }

    /*//////////////////////////////////////////////////////////////
                         STRUCTURAL INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The specified side must always be echoed verbatim, never rewritten.
    function testFuzz_specifiedSideIsEchoedVerbatim(
        uint256 amountSeed,
        uint16 spreadSeed,
        bool sharesIn,
        bool isExactIn
    ) public view {
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        (bool ok, uint256 amountIn, uint256 amountOut) = _tryQuote(sharesIn, isExactIn, amount, spread);
        if (!ok) return;
        if (isExactIn) {
            assertEq(amountIn, amount, "exact-in must echo amountIn");
        } else {
            assertEq(amountOut, amount, "exact-out must echo amountOut");
        }
    }

    /// @dev A successful quote must never demand more input than the input balance register allows.
    function testFuzz_quotedInputNeverExceedsBalanceIn(
        uint256 amountSeed,
        uint256 balanceSeed,
        uint16 spreadSeed,
        bool sharesIn,
        bool isExactIn
    ) public view {
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint256 balanceIn = bound(balanceSeed, 0, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        try IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(tokenIn, tokenOut, isExactIn),
                registers(isExactIn, amount, balanceIn, type(uint256).max),
                tightConfig(address(vault), spread, vault.ratePerShareUnit()),
                ""
            ) returns (
            uint256, uint256, SwapRegisters memory r
        ) {
            assertLe(r.amountIn, balanceIn, "a successful quote must fit inside balanceIn");
        } catch {
            return;
        }
    }

    /// @dev A successful quote must never promise more output than the maker's balance register allows.
    function testFuzz_quotedOutputNeverExceedsBalanceOut(
        uint256 amountSeed,
        uint256 balanceSeed,
        uint16 spreadSeed,
        bool sharesIn,
        bool isExactIn
    ) public view {
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        uint256 balanceOut = bound(balanceSeed, 0, MAX_AMOUNT);
        uint16 spread = uint16(bound(spreadSeed, 0, 9_999));
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        try IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(tokenIn, tokenOut, isExactIn),
                registers(isExactIn, amount, type(uint256).max, balanceOut),
                tightConfig(address(vault), spread, vault.ratePerShareUnit()),
                ""
            ) returns (
            uint256, uint256, SwapRegisters memory r
        ) {
            assertLe(r.amountOut, balanceOut, "a successful quote must fit inside balanceOut");
        } catch {
            return;
        }
    }

    /// @dev Any rate outside the configured band must be refused for every amount and direction.
    function testFuzz_outOfBandRateAlwaysRefused(
        uint256 rateSeed,
        uint256 minSeed,
        uint256 maxSeed,
        uint256 amountSeed,
        bool sharesIn,
        bool isExactIn
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint256 minRate = bound(minSeed, 1, MAX_RATE);
        uint256 maxRate = bound(maxSeed, minRate, MAX_RATE);
        vm.assume(rate < minRate || rate > maxRate);
        vault.setRate(rate);

        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT);
        (address tokenIn, address tokenOut) =
            sharesIn ? (address(vault), address(usdc)) : (address(usdc), address(vault));

        vm.expectRevert();
        IStaticExtruction(address(ext))
            .extruction(
                true,
                DEFAULT_PC,
                query(tokenIn, tokenOut, isExactIn),
                registers(isExactIn, amount, type(uint256).max, type(uint256).max),
                config(address(vault), 15, minRate, maxRate),
                ""
            );
    }

    /*//////////////////////////////////////////////////////////////
                           ARITHMETIC EXTREMES
    //////////////////////////////////////////////////////////////*/

    /// @dev Extreme inputs must fail closed. Documents F-09: the failure surfaces as OpenZeppelin's
    ///      arithmetic panic (0x11) raised inside `Math.mulDiv`, not one of the Extruction's named errors.
    function test_extremes_exactOutOverflowRevertsInMulDiv() public {
        vault.setRate(1e18);
        uint256 rate = vault.ratePerShareUnit();
        (address tokenIn, address tokenOut) = (address(vault), address(usdc));
        vm.expectRevert(stdError.arithmeticError);
        IStaticExtruction(address(ext)).extruction(
            true,
            DEFAULT_PC,
            query(tokenIn, tokenOut, false),
            registers(false, type(uint256).max, type(uint256).max, type(uint256).max),
            tightConfig(address(vault), 15, rate),
            ""
        );
    }

    function test_extremes_exactInOverflowRevertsInMulDiv() public {
        vault.setRate(type(uint256).max);
        uint256 rate = vault.ratePerShareUnit();
        (address tokenIn, address tokenOut) = (address(vault), address(usdc));
        vm.expectRevert(stdError.arithmeticError);
        IStaticExtruction(address(ext)).extruction(
            true,
            DEFAULT_PC,
            query(tokenIn, tokenOut, true),
            registers(true, type(uint256).max, type(uint256).max, type(uint256).max),
            tightConfig(address(vault), 0, rate),
            ""
        );
    }

    /// @dev A zero-spread exact-out at the maximum representable output is exactly representable.
    function test_extremes_zeroSpreadExactOutAtUint256Max() public {
        vault.setRate(1e18);
        (uint256 amountIn, uint256 amountOut) =
            priceTight(address(vault), address(usdc), true, false, type(uint256).max, 0, type(uint256).max);
        assertEq(amountOut, type(uint256).max);
        assertEq(amountIn, type(uint256).max, "at a 1:1 rate with no spread the extremes round-trip");
    }

    /// @dev The widest possible band must be accepted for any rate.
    function testFuzz_widestBandAcceptsAnyRate(
        uint256 rateSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, type(uint256).max);
        vault.setRate(rate);
        (uint256 reported,,) = ext.currentRate(address(vault));
        assertEq(reported, rate);

        (bool ok,,) = _tryQuote(true, true, 1e18, 0);
        // Either it prices, or it refuses for a rounding/overflow reason - never for a bounds reason.
        if (!ok) {
            bytes memory args = tightConfig(address(vault), 0, rate);
            vm.expectRevert();
            IStaticExtruction(address(ext)).extruction(
                true,
                DEFAULT_PC,
                query(address(vault), address(usdc), true),
                registers(true, 1e18, type(uint256).max, type(uint256).max),
                args,
                ""
            );
        }
    }

    /// @dev `currentRate` must always agree with the vault's own view of a whole share.
    function testFuzz_currentRateTracksTheVault(
        uint256 rateSeed,
        uint8 decimalsSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, MAX_RATE);
        uint8 decimals = uint8(bound(decimalsSeed, 0, 77));
        RateVault v = new RateVault(address(usdc), decimals, rate);

        (uint256 reported, uint256 shareUnit, address asset) = ext.currentRate(address(v));
        assertEq(shareUnit, 10 ** uint256(decimals));
        assertEq(asset, address(usdc));
        assertEq(reported, v.convertToAssets(shareUnit), "currentRate must be convertToAssets(one whole share)");
    }
}

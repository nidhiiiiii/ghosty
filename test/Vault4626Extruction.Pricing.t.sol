// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";
import {RateVault} from "./mocks/MockVaults.sol";

/// @notice Golden-vector pricing tests. Every expected number below is computed by hand in the comment
///         above it rather than by re-deriving it from the contract's own formula.
contract Vault4626ExtructionPricingTest is AquiferTestBase {
    MockERC20 internal usdc;
    MockERC20 internal weth;

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
    }

    function _vault(
        address asset,
        uint8 shareDecimals,
        uint256 rate
    ) internal returns (RateVault) {
        return new RateVault(asset, shareDecimals, rate);
    }

    /*//////////////////////////////////////////////////////////////
                        6-DECIMAL ASSET / 18-DECIMAL SHARE
    //////////////////////////////////////////////////////////////*/

    // shareUnit = 1e18, rate = 1_050_000 (1.05 USDC per share), spread = 15bps => keptBps = 9985.
    // fair     = 1e18 * 1_050_000 / 1e18 = 1_050_000
    // amountOut= 1_050_000 * 9985 / 10_000 = 10_484_250_000 / 10_000 = 1_048_425
    function test_exactIn_sharesIn_goldenVector() public {
        RateVault vault = _vault(address(usdc), 18, 1_050_000);
        (uint256 amountIn, uint256 amountOut) =
            priceTight(address(vault), address(usdc), true, true, 1e18, 15, type(uint256).max);
        assertEq(amountIn, 1e18, "exact-in must echo the specified amountIn");
        assertEq(amountOut, 1_048_425, "1 share at 1.05 USDC minus 15bps");
    }

    // shareUnit = 1e18, rate = 1_050_000, spread = 15bps.
    // amountIn = 1_050_000 asset units.
    // fair     = 1_050_000 * 1e18 / 1_050_000 = 1e18 shares
    // amountOut= 1e18 * 9985 / 10_000 = 998_500_000_000_000_000
    function test_exactIn_assetsIn_goldenVector() public {
        RateVault vault = _vault(address(usdc), 18, 1_050_000);
        (uint256 amountIn, uint256 amountOut) =
            priceTight(address(vault), address(usdc), false, true, 1_050_000, 15, type(uint256).max);
        assertEq(amountIn, 1_050_000);
        assertEq(amountOut, 998_500_000_000_000_000, "1.05 USDC buys 0.9985 shares at 15bps");
    }

    // Exact-out is the arithmetic inverse of test_exactIn_sharesIn_goldenVector.
    // amountOut = 1_048_425 asset units, keptBps = 9985.
    // fair      = ceil(1_048_425 * 10_000 / 9985) = ceil(10_484_250_000 / 9985) = 1_050_000 (exact)
    // amountIn  = ceil(1_050_000 * 1e18 / 1_050_000) = 1e18
    function test_exactOut_sharesIn_goldenVector() public {
        RateVault vault = _vault(address(usdc), 18, 1_050_000);
        (uint256 amountIn, uint256 amountOut) =
            priceTight(address(vault), address(usdc), true, false, 1_048_425, 15, type(uint256).max);
        assertEq(amountOut, 1_048_425, "exact-out must echo the specified amountOut");
        assertEq(amountIn, 1e18, "exact-out is the exact inverse of the exact-in vector");
    }

    // amountOut = 998_500_000_000_000_000 shares, keptBps = 9985.
    // fair      = ceil(9.985e17 * 10_000 / 9985) = ceil(9.985e21 / 9985) = 1e18 (exact)
    // amountIn  = ceil(1e18 * 1_050_000 / 1e18) = 1_050_000
    function test_exactOut_assetsIn_goldenVector() public {
        RateVault vault = _vault(address(usdc), 18, 1_050_000);
        (uint256 amountIn, uint256 amountOut) =
            priceTight(address(vault), address(usdc), false, false, 998_500_000_000_000_000, 15, type(uint256).max);
        assertEq(amountOut, 998_500_000_000_000_000);
        assertEq(amountIn, 1_050_000);
    }

    /*//////////////////////////////////////////////////////////////
                                SPREAD
    //////////////////////////////////////////////////////////////*/

    // spread = 0 => keptBps = BPS => pricing is the raw vault rate in both directions.
    function test_zeroSpread_isIdentityAtUnitRate() public {
        RateVault vault = _vault(address(weth), 18, 1e18);
        (, uint256 outExactIn) =
            priceTight(address(vault), address(weth), true, true, 12_345, 0, type(uint256).max);
        assertEq(outExactIn, 12_345, "zero spread at 1:1 must be the identity");

        (uint256 inExactOut,) =
            priceTight(address(vault), address(weth), true, false, 12_345, 0, type(uint256).max);
        assertEq(inExactOut, 12_345, "zero spread exact-out must also be the identity");
    }

    // spread = 9_999 (the largest accepted value) => keptBps = 1.
    // exact-in : out = floor(10_000 * 1 / 10_000) = 1
    // exact-out: fair = ceil(1 * 10_000 / 1) = 10_000 => in = 10_000
    function test_maximumSpread_9999() public {
        RateVault vault = _vault(address(weth), 18, 1e18);
        (, uint256 amountOut) = priceTight(address(vault), address(weth), true, true, 10_000, 9_999, type(uint256).max);
        assertEq(amountOut, 1, "99.99% spread leaves 1 unit out of 10_000");

        (uint256 amountIn,) =
            priceTight(address(vault), address(weth), true, false, 1, 9_999, type(uint256).max);
        assertEq(amountIn, 10_000, "buying 1 unit out costs 10_000 in at 99.99% spread");
    }

    // Exact-in floors the spread deduction, so the maker keeps the dust.
    // rate 1:1, spread 1bps => keptBps = 9_999.
    // amountIn = 10_000 => out = floor(10_000 * 9_999 / 10_000) = 9_999
    // amountIn = 9_999  => out = floor(9_999 * 9_999 / 10_000) = floor(9_998.0001) = 9_998
    function test_exactIn_spreadRoundsDownInMakerFavour() public {
        RateVault vault = _vault(address(weth), 18, 1e18);
        (, uint256 a) =
            priceTight(address(vault), address(weth), true, true, 10_000, 1, type(uint256).max);
        assertEq(a, 9_999);

        (, uint256 b) =
            priceTight(address(vault), address(weth), true, true, 9_999, 1, type(uint256).max);
        assertEq(b, 9_998);
    }

    // Exact-out ceils twice, so dust trades are priced strictly against the taker.
    // rate 1:1, spread 1bps => keptBps = 9_999.
    // amountOut = 1 => fair = ceil(10_000 / 9_999) = 2 => amountIn = ceil(2 * 1e18 / 1e18) = 2
    function test_exactOut_spreadRoundsUpInMakerFavour() public {
        RateVault vault = _vault(address(weth), 18, 1e18);
        (uint256 amountIn,) =
            priceTight(address(vault), address(weth), true, false, 1, 1, type(uint256).max);
        assertEq(amountIn, 2, "1-unit exact-out costs 2 units in: rounding must favour the maker");
    }

    /*//////////////////////////////////////////////////////////////
                             DECIMALS MATRIX
    //////////////////////////////////////////////////////////////*/

    // 18-decimal asset, 6-decimal share. shareUnit = 1e6, rate = 1.05e18 assets per whole share.
    // exact-in 1e6 shares: fair = 1e6 * 1.05e18 / 1e6 = 1.05e18; spread 0 => out = 1.05e18
    function test_decimals_asset18_share6() public {
        RateVault vault = _vault(address(weth), 6, 1_050_000_000_000_000_000);
        (, uint256 amountOut) =
            priceTight(address(vault), address(weth), true, true, 1e6, 0, type(uint256).max);
        assertEq(amountOut, 1_050_000_000_000_000_000);
    }

    // 0-decimal asset and 0-decimal share. shareUnit = 1, rate = 3 assets per share.
    // exact-in 5 shares: fair = 5 * 3 / 1 = 15; spread 0 => out = 15
    function test_decimals_zeroDecimalsBothSides() public {
        MockERC20 wei0 = new MockERC20("Zero", "ZERO", 0);
        RateVault vault = _vault(address(wei0), 0, 3);
        (, uint256 amountOut) =
            priceTight(address(vault), address(wei0), true, true, 5, 0, type(uint256).max);
        assertEq(amountOut, 15);

        // exact-out 15 assets: fair = 15, in = ceil(15 * 1 / 3) = 5
        (uint256 amountIn,) =
            priceTight(address(vault), address(wei0), true, false, 15, 0, type(uint256).max);
        assertEq(amountIn, 5);
    }

    // MAX_SAFE_DECIMALS boundary. 10**77 < type(uint256).max, so shareUnit is representable.
    // rate = 1e77 == shareUnit, so pricing is 1:1 and mulDiv must not overflow at 512-bit width.
    function test_decimals_maxSafeDecimals77_isAccepted() public {
        uint256 unit77 = 10 ** 77;
        RateVault vault = _vault(address(weth), 77, unit77);
        (, uint256 amountOut) =
            priceTight(address(vault), address(weth), true, true, 1e18, 0, type(uint256).max);
        assertEq(amountOut, 1e18, "decimals == MAX_SAFE_DECIMALS must price, not revert");

        (uint256 rate, uint256 shareUnit,) = ext.currentRate(address(vault));
        assertEq(shareUnit, unit77);
        assertEq(rate, unit77);
    }

    function test_decimals_78_revertsInvalidShareDecimals() public {
        RateVault vault = _vault(address(weth), 78, 1);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidShareDecimals.selector, uint8(78)));
        ext.currentRate(address(vault));
    }

    function test_decimals_255_revertsInvalidShareDecimals() public {
        RateVault vault = _vault(address(weth), 255, 1);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidShareDecimals.selector, uint8(255)));
        ext.currentRate(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                        PRECISION LOSS / DUST
    //////////////////////////////////////////////////////////////*/

    // A 6-decimal asset against an 18-decimal share truncates sub-unit share amounts to zero assets.
    // amountIn = 1e11 shares (1e-7 of a share): fair = 1e11 * 1_000_000 / 1e18 = 0.
    function test_exactIn_dustSharesRoundToZero_reverts() public {
        RateVault vault = _vault(address(usdc), 18, 1_000_000);
        (address tokenIn, address tokenOut) = (address(vault), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.AmountRoundsToZero.selector, uint256(1e11)));
        quoteCurrent(
            query(tokenIn, tokenOut, true),
            registers(true, 1e11, type(uint256).max, type(uint256).max),
            tightConfig(address(vault), 0, 1_000_000)
        );
    }

    // The smallest exact-in share amount that survives truncation is 1e12 (=> exactly 1 asset unit).
    function test_exactIn_smallestNonZeroSharesIn() public {
        RateVault vault = _vault(address(usdc), 18, 1_000_000);
        (, uint256 amountOut) =
            priceTight(address(vault), address(usdc), true, true, 1e12, 0, type(uint256).max);
        assertEq(amountOut, 1, "1e12 share units is exactly one 6-decimal asset unit");
    }

    // Exact-out never rounds the input down to zero: ceil guarantees at least 1.
    function test_exactOut_oneUnitOutAlwaysCostsAtLeastOneIn() public {
        RateVault vault = _vault(address(usdc), 18, 1_000_000);
        (uint256 amountIn,) =
            priceTight(address(vault), address(usdc), false, false, 1, 0, type(uint256).max);
        // 1 share unit out at 1 USDC/share: fair = 1, in = ceil(1 * 1_000_000 / 1e18) = 1
        assertEq(amountIn, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        ZERO SPECIFIED AMOUNT
    //////////////////////////////////////////////////////////////*/

    function test_zeroSpecifiedAmount_revertsForBothModes() public {
        RateVault vault = _vault(address(usdc), 18, 1_050_000);

        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroSpecifiedAmount.selector, true));
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 0, type(uint256).max, 0),
            tightConfig(address(vault), 15, 1_050_000)
        );

        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroSpecifiedAmount.selector, false));
        quoteCurrent(
            query(address(vault), address(usdc), false),
            registers(false, 0, type(uint256).max, 0),
            tightConfig(address(vault), 15, 1_050_000)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            currentRate()
    //////////////////////////////////////////////////////////////*/

    function test_currentRate_reportsRateShareUnitAndAsset() public {
        RateVault vault = _vault(address(usdc), 18, 1_234_567);
        (uint256 rate, uint256 shareUnit, address asset) = ext.currentRate(address(vault));
        assertEq(rate, 1_234_567);
        assertEq(shareUnit, 1e18);
        assertEq(asset, address(usdc));
    }

    function test_constants() public view {
        assertEq(ext.BPS(), 10_000);
        assertEq(ext.CONFIG_LENGTH(), 128);
        assertEq(ext.MAX_SAFE_DECIMALS(), 77);
        assertEq(ext.MAX_RATE_DEVIATION_BPS(), 100);
        assertEq(ext.RATE_ROUNDTRIP_BPS(), 10);
    }
}

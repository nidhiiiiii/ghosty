// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";
import {CodeStub, RateVault, RawReturnVault, RevertingVault, SelfAssetVault} from "./mocks/MockVaults.sol";

/// @notice Validation, bounds, pair, recompute and liquidity guards.
contract Vault4626ExtructionGuardsTest is AquiferTestBase {
    MockERC20 internal usdc;
    RateVault internal vault;

    function setUp() public override {
        super.setUp();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new RateVault(address(usdc), 18, 1_000_000);
    }

    function _ok() internal view returns (bytes memory) {
        return config(address(vault), 15, 900_000, 1_100_000);
    }

    function _quoteShares(
        uint256 amountIn,
        bytes memory args
    ) internal view {
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, amountIn, type(uint256).max, type(uint256).max),
            args
        );
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG LENGTH
    //////////////////////////////////////////////////////////////*/

    function test_configLength_empty_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, 0, 128));
        _quoteShares(1e18, "");
    }

    function test_configLength_oneByteShort_reverts() public {
        bytes memory short = new bytes(127);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, 127, 128));
        _quoteShares(1e18, short);
    }

    function test_configLength_oneByteLong_reverts() public {
        bytes memory long = new bytes(129);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, 129, 128));
        _quoteShares(1e18, long);
    }

    /// @dev A trailing extra word is the most likely real-world mis-encoding; it must not be silently accepted.
    function test_configLength_extraTrailingWord_reverts() public {
        bytes memory tooLong = abi.encodePacked(_ok(), bytes32(0));
        assertEq(tooLong.length, 160);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, 160, 128));
        _quoteShares(1e18, tooLong);
    }

    function testFuzz_configLength_anyWrongLengthReverts(
        uint16 len
    ) public {
        uint256 n = uint256(len) % 512;
        vm.assume(n != 128);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, n, 128));
        _quoteShares(1e18, new bytes(n));
    }

    /*//////////////////////////////////////////////////////////////
                            MALFORMED CONFIG
    //////////////////////////////////////////////////////////////*/

    function test_malformedConfig_dirtyVaultPadding_reverts() public {
        bytes memory args = rawConfig(uint256(uint160(address(vault))) | (uint256(1) << 160), 15, 900_000, 1_100_000);
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteShares(1e18, args);
    }

    function test_malformedConfig_dirtySpreadPadding_reverts() public {
        bytes memory args = rawConfig(uint256(uint160(address(vault))), (uint256(1) << 16) | 15, 900_000, 1_100_000);
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteShares(1e18, args);
    }

    function test_malformedConfig_topBitOfEachWord_reverts() public {
        bytes memory dirtyVault =
            rawConfig(uint256(uint160(address(vault))) | (uint256(1) << 255), 15, 900_000, 1_100_000);
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteShares(1e18, dirtyVault);

        bytes memory dirtySpread =
            rawConfig(uint256(uint160(address(vault))), uint256(15) | (uint256(1) << 255), 900_000, 1_100_000);
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteShares(1e18, dirtySpread);
    }

    /// @dev Clean canonical encoding must survive the padding check.
    function test_malformedConfig_canonicalEncodingAccepted() public view {
        _quoteShares(1e18, _ok());
    }

    function testFuzz_malformedConfig_anyHighBitReverts(
        uint96 vaultDirt,
        uint240 spreadDirt
    ) public {
        vm.assume(vaultDirt != 0 || spreadDirt != 0);
        bytes memory args = rawConfig(
            uint256(uint160(address(vault))) | (uint256(vaultDirt) << 160),
            uint256(15) | (uint256(spreadDirt) << 16),
            900_000,
            1_100_000
        );
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteShares(1e18, args);
    }

    /// @dev The decoder's raw calldata reads must land on the same fields the canonical ABI decoder would.
    function testFuzz_configDecode_matchesAbiEncoding(
        address v,
        uint16 spread,
        uint256 minRate,
        uint256 maxRate
    ) public view {
        bytes memory encoded = ext.encodeConfig(v, spread, minRate, maxRate);
        (address dv, uint16 ds, uint256 dmin, uint256 dmax) = abi.decode(encoded, (address, uint16, uint256, uint256));
        assertEq(dv, v);
        assertEq(ds, spread);
        assertEq(dmin, minRate);
        assertEq(dmax, maxRate);
        assertEq(encoded.length, ext.CONFIG_LENGTH());
    }

    /*//////////////////////////////////////////////////////////////
                                SPREAD
    //////////////////////////////////////////////////////////////*/

    function test_spread_equalToBps_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidSpread.selector, uint256(10_000)));
        _quoteShares(1e18, config(address(vault), 10_000, 900_000, 1_100_000));
    }

    function test_spread_uint16Max_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidSpread.selector, uint256(65_535)));
        _quoteShares(1e18, config(address(vault), type(uint16).max, 900_000, 1_100_000));
    }

    function test_spread_9999_accepted() public view {
        _quoteShares(1e18, config(address(vault), 9_999, 900_000, 1_100_000));
    }

    function testFuzz_spread_atOrAboveBpsAlwaysReverts(
        uint16 spread
    ) public {
        vm.assume(spread >= 10_000);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidSpread.selector, uint256(spread)));
        _quoteShares(1e18, config(address(vault), spread, 900_000, 1_100_000));
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_bounds_zeroMinRate_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidBounds.selector, 0, 1_100_000));
        _quoteShares(1e18, config(address(vault), 15, 0, 1_100_000));
    }

    function test_bounds_maxBelowMin_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidBounds.selector, 1_100_000, 900_000));
        _quoteShares(1e18, config(address(vault), 15, 1_100_000, 900_000));
    }

    function test_bounds_bothZero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidBounds.selector, 0, 0));
        _quoteShares(1e18, config(address(vault), 15, 0, 0));
    }

    function test_bounds_degenerateEqualBoundsAtExactRate_accepted() public view {
        _quoteShares(1e18, config(address(vault), 15, 1_000_000, 1_000_000));
    }

    function test_bounds_rateAtMinIsInclusive() public view {
        _quoteShares(1e18, config(address(vault), 15, 1_000_000, 2_000_000));
    }

    function test_bounds_rateAtMaxIsInclusive() public view {
        _quoteShares(1e18, config(address(vault), 15, 500_000, 1_000_000));
    }

    function test_bounds_rateOneBelowMin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, 1_000_000, 1_000_001, 2_000_000)
        );
        _quoteShares(1e18, config(address(vault), 15, 1_000_001, 2_000_000));
    }

    function test_bounds_rateOneAboveMax_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, 1_000_000, 500_000, 999_999)
        );
        _quoteShares(1e18, config(address(vault), 15, 500_000, 999_999));
    }

    /// @dev Bounds are checked before the pair check, so a bad rate cannot be masked by a bad pair.
    function test_bounds_checkedBeforePairCheck() public {
        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, 1_000_000, 2_000_000, 3_000_000)
        );
        quoteCurrent(
            query(address(0xdead), address(0xbeef), true),
            registers(true, 1e18, type(uint256).max, type(uint256).max),
            config(address(vault), 15, 2_000_000, 3_000_000)
        );
    }

    /// @dev Spread and bounds are validated before the vault is ever touched.
    function test_configValidation_precedesVaultRead() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidSpread.selector, uint256(10_000)));
        _quoteShares(1e18, config(address(0), 10_000, 900_000, 1_100_000));

        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidBounds.selector, 0, 0));
        _quoteShares(1e18, config(address(0), 15, 0, 0));
    }

    /*//////////////////////////////////////////////////////////////
                            INVALID VAULT / ASSET
    //////////////////////////////////////////////////////////////*/

    function test_invalidVault_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidVault.selector, address(0)));
        _quoteShares(1e18, config(address(0), 15, 900_000, 1_100_000));

        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidVault.selector, address(0)));
        ext.currentRate(address(0));
    }

    function test_invalidVault_eoa_reverts() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidVault.selector, eoa));
        _quoteShares(1e18, config(eoa, 15, 900_000, 1_100_000));
    }

    function test_invalidAsset_zeroAddress_reverts() public {
        RateVault v = new RateVault(address(0), 18, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidAsset.selector, address(0)));
        ext.currentRate(address(v));
    }

    function test_invalidAsset_eoa_reverts() public {
        address eoa = makeAddr("assetEoa");
        RateVault v = new RateVault(eoa, 18, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidAsset.selector, eoa));
        ext.currentRate(address(v));
    }

    /// @dev A contract with code but no ERC-20 behaviour passes the code-length check. Documented as F-07.
    function test_invalidAsset_codeWithoutErc20Behaviour_isAccepted() public {
        CodeStub stub = new CodeStub();
        RateVault v = new RateVault(address(stub), 18, 1_000_000);
        (uint256 rate,, address asset) = ext.currentRate(address(v));
        assertEq(rate, 1_000_000);
        assertEq(asset, address(stub));
    }

    function test_zeroVaultRate_reverts() public {
        RateVault v = new RateVault(address(usdc), 18, 0);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroVaultRate.selector, address(v)));
        ext.currentRate(address(v));
    }

    function test_vaultAssetReverts_bubblesUp() public {
        RevertingVault v = new RevertingVault(address(usdc), RevertingVault.Mode.AssetReverts);
        vm.expectRevert(RevertingVault.VaultBoom.selector);
        ext.currentRate(address(v));
    }

    function test_vaultDecimalsReverts_bubblesUp() public {
        RevertingVault v = new RevertingVault(address(usdc), RevertingVault.Mode.DecimalsReverts);
        vm.expectRevert(RevertingVault.VaultBoom.selector);
        ext.currentRate(address(v));
    }

    function test_vaultConvertToAssetsReverts_bubblesUp() public {
        RevertingVault v = new RevertingVault(address(usdc), RevertingVault.Mode.ConvertReverts);
        vm.expectRevert(RevertingVault.VaultBoom.selector);
        ext.currentRate(address(v));
    }

    /// @dev A vault whose decimals() word exceeds uint8 fails in the ABI decoder, not in InvalidShareDecimals.
    function test_vaultDecimalsOverflowsUint8_revertsInDecoder() public {
        RawReturnVault v =
            new RawReturnVault(abi.encode(address(usdc)), abi.encode(uint256(300)), abi.encode(uint256(1e18)));
        vm.expectRevert();
        ext.currentRate(address(v));
    }

    /// @dev A vault returning no data for asset() fails in the ABI decoder.
    function test_vaultAssetReturnsNothing_revertsInDecoder() public {
        RawReturnVault v = new RawReturnVault("", abi.encode(uint256(18)), abi.encode(uint256(1e18)));
        vm.expectRevert();
        ext.currentRate(address(v));
    }

    /*//////////////////////////////////////////////////////////////
                            UNSUPPORTED PAIR
    //////////////////////////////////////////////////////////////*/

    function _expectUnsupported(
        address tokenIn,
        address tokenOut
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                Vault4626Extruction.UnsupportedPair.selector, tokenIn, tokenOut, address(vault), address(usdc)
            )
        );
        quoteCurrent(query(tokenIn, tokenOut, true), registers(true, 1e18, type(uint256).max, type(uint256).max), _ok());
    }

    function test_unsupportedPair_bothUnrelated() public {
        _expectUnsupported(address(0xa11ce), address(0xb0b));
    }

    function test_unsupportedPair_vaultAgainstUnrelated() public {
        _expectUnsupported(address(vault), address(0xb0b));
    }

    function test_unsupportedPair_unrelatedAgainstAsset() public {
        _expectUnsupported(address(0xa11ce), address(usdc));
    }

    function test_unsupportedPair_vaultToVault() public {
        _expectUnsupported(address(vault), address(vault));
    }

    function test_unsupportedPair_assetToAsset() public {
        _expectUnsupported(address(usdc), address(usdc));
    }

    function test_unsupportedPair_zeroTokens() public {
        _expectUnsupported(address(0), address(0));
    }

    /// @dev Reversed-direction pairs with a *different* vault's asset must also be rejected.
    function test_unsupportedPair_otherVaultsAsset() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        _expectUnsupported(address(vault), address(dai));
    }

    function test_selfReferentialVault_reverts() public {
        SelfAssetVault sv = new SelfAssetVault();
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.SelfReferentialAsset.selector, address(sv)));
        ext.currentRate(address(sv));
    }

    /*//////////////////////////////////////////////////////////////
                            RECOMPUTE GUARD
    //////////////////////////////////////////////////////////////*/

    function test_recompute_exactIn_withPopulatedAmountOut_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, true, uint256(99)));
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registersRaw(type(uint256).max, type(uint256).max, 1e18, 99),
            _ok()
        );
    }

    function test_recompute_exactOut_withPopulatedAmountIn_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, false, uint256(77)));
        quoteCurrent(
            query(address(vault), address(usdc), false),
            registersRaw(type(uint256).max, type(uint256).max, 77, 1e18),
            _ok()
        );
    }

    /// @dev The guard fires before config decoding, so it cannot be bypassed with malformed args.
    function test_recompute_firesBeforeConfigDecode() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, true, uint256(1)));
        quoteCurrent(
            query(address(vault), address(usdc), true), registersRaw(type(uint256).max, type(uint256).max, 1e18, 1), ""
        );
    }

    function testFuzz_recompute_anyNonZeroOppositeRegisterReverts(
        bool isExactIn,
        uint256 dirty
    ) public {
        vm.assume(dirty != 0);
        (uint256 aIn, uint256 aOut) = isExactIn ? (uint256(1e18), dirty) : (dirty, uint256(1e18));
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, isExactIn, dirty));
        quoteCurrent(
            query(address(vault), address(usdc), isExactIn),
            registersRaw(type(uint256).max, type(uint256).max, aIn, aOut),
            _ok()
        );
    }

    /*//////////////////////////////////////////////////////////////
                          INSUFFICIENT LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    // 1e18 shares at rate 1_000_000 with 15bps spread:
    // fair = 1_000_000, out = floor(1_000_000 * 9_985 / 10_000) = 998_500
    function test_liquidity_exactIn_exactlyEnough_accepted() public view {
        (, uint256 amountOut) =
            priceCurrent(address(vault), address(usdc), true, true, 1e18, 15, 900_000, 1_100_000, 998_500);
        assertEq(amountOut, 998_500);
    }

    function test_liquidity_exactIn_oneShort_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InsufficientLiquidity.selector, 998_500, 998_499));
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, 998_499),
            config(address(vault), 15, 900_000, 1_100_000)
        );
    }

    function test_liquidity_exactIn_zeroBalanceOut_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InsufficientLiquidity.selector, 998_500, 0));
        quoteCurrent(
            query(address(vault), address(usdc), true),
            registers(true, 1e18, type(uint256).max, 0),
            config(address(vault), 15, 900_000, 1_100_000)
        );
    }

    function test_liquidity_exactOut_exactlyEnough_accepted() public view {
        (uint256 amountIn,) =
            priceCurrent(address(vault), address(usdc), true, false, 500_000, 15, 900_000, 1_100_000, 500_000);
        assertGt(amountIn, 0);
    }

    function test_liquidity_exactOut_oneShort_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InsufficientLiquidity.selector, 500_000, 499_999));
        quoteCurrent(
            query(address(vault), address(usdc), false),
            registers(false, 500_000, type(uint256).max, 499_999),
            config(address(vault), 15, 900_000, 1_100_000)
        );
    }

    /// @dev The liquidity guard is the last check, so it must not mask a rounding failure.
    function test_liquidity_checkedAfterRoundsToZero() public {
        RateVault v = new RateVault(address(usdc), 18, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.AmountRoundsToZero.selector, uint256(1)));
        quoteCurrent(
            query(address(v), address(usdc), true),
            registers(true, 1, type(uint256).max, 0),
            config(address(v), 0, 1, type(uint256).max)
        );
    }

    /// @dev balanceIn is never consulted, so an exact-out quote can demand more input than the maker has.
    ///      Documented as F-08.
    function test_liquidity_balanceInIsIgnored() public view {
        (uint256 amountIn,) =
            priceCurrent(address(vault), address(usdc), true, false, 998_500, 15, 900_000, 1_100_000, 998_500);
        assertEq(amountIn, 1e18);

        // Same quote with balanceIn set to 1 still succeeds.
        Result memory r = quoteCurrent(
            query(address(vault), address(usdc), false),
            registers(false, 998_500, 1, 998_500),
            config(address(vault), 15, 900_000, 1_100_000)
        );
        assertEq(r.amountIn, 1e18);
        assertEq(r.balanceIn, 1);
    }
}

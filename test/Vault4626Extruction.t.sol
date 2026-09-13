// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {
    IExtruction,
    IStaticExtruction,
    IStaticExtructionV102,
    SwapQuery,
    SwapRegisters,
    SwapRegistersV102
} from "../src/interfaces/ISwapVMExtruction.sol";
import {AquiferStrategy} from "../src/libraries/AquiferStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockERC4626} from "../src/mocks/MockERC4626.sol";

contract VaultStub {
    address private immutable _asset;
    uint8 private immutable _decimals;
    uint256 private immutable _rate;

    constructor(
        address asset_,
        uint8 decimals_,
        uint256 rate_
    ) {
        _asset = asset_;
        _decimals = decimals_;
        _rate = rate_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function convertToAssets(
        uint256
    ) external view returns (uint256) {
        return _rate;
    }
}

contract SelfReferentialVault {
    function asset() external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function convertToAssets(
        uint256 shares
    ) external pure returns (uint256) {
        return shares;
    }
}

contract Vault4626ExtructionTest is Test {
    uint256 private constant BPS = 10_000;
    uint16 private constant SPREAD = 15;
    uint256 private constant SHARE_UNIT = 1e18;
    uint256 private constant ASSET_UNIT = 1e6;

    MockERC20 private asset;
    MockERC4626 private vault;
    Vault4626Extruction private target;

    function setUp() external {
        asset = new MockERC20("Demo USD", "dUSD", 6);
        vault = new MockERC4626(asset, 12);
        target = new Vault4626Extruction();

        asset.mint(address(this), 1_000_000e6);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, address(this));
    }

    function testCurrentRateAccountsForDifferentDecimals() external view {
        (uint256 rate, uint256 shareUnit, address underlying) = target.currentRate(address(vault));
        assertEq(rate, ASSET_UNIT);
        assertEq(shareUnit, SHARE_UNIT);
        assertEq(underlying, address(asset));
    }

    function testExactInputSharesToAssetsAppliesSpread() external view {
        uint256 amountIn = 100e18;
        SwapRegisters memory registers = _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, amountIn, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );

        assertEq(registers.amountIn, amountIn);
        assertEq(registers.amountOut, 99_850_000);
    }

    function testExactInputAssetsToSharesAppliesSpread() external view {
        uint256 amountIn = 100e6;
        SwapRegisters memory registers = _quoteCurrent(
            _query(address(asset), address(vault), true),
            _registers(type(uint256).max, amountIn, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );

        assertEq(registers.amountIn, amountIn);
        assertEq(registers.amountOut, 99.85e18);
    }

    function testExactOutputSharesToAssetsRoundsInputUp() external view {
        uint256 requestedOut = 100e6;
        SwapRegisters memory registers = _quoteCurrent(
            _query(address(vault), address(asset), false),
            _registers(type(uint256).max, 0, requestedOut),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );

        uint256 fairOutput = _ceilDiv(requestedOut * BPS, BPS - SPREAD);
        assertEq(registers.amountIn, fairOutput * 1e12);
        assertEq(registers.amountOut, requestedOut);
    }

    function testExactOutputAssetsToSharesRoundsInputUp() external view {
        uint256 requestedOut = 100e18;
        SwapRegisters memory registers = _quoteCurrent(
            _query(address(asset), address(vault), false),
            _registers(type(uint256).max, 0, requestedOut),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );

        assertEq(registers.amountIn, _ceilDiv(100e6 * BPS, BPS - SPREAD));
        assertEq(registers.amountOut, requestedOut);
    }

    function testV102PreservesFeeRegister() external view {
        SwapRegistersV102 memory input = SwapRegistersV102({
            balanceIn: 300e18, balanceOut: 500e6, amountIn: 10e18, amountOut: 0, amountNetPulled: 123_456
        });

        (uint256 nextPc, uint256 chopped, SwapRegistersV102 memory output) = IStaticExtructionV102(address(target))
            .extruction(
                true,
                77,
                _query(address(vault), address(asset), true),
                input,
                _config(SPREAD, ASSET_UNIT, ASSET_UNIT),
                hex"cafe"
            );

        assertEq(nextPc, 77);
        assertEq(chopped, 0);
        assertEq(output.amountOut, 9_985_000);
        assertEq(output.amountNetPulled, input.amountNetPulled);
        assertEq(output.balanceIn, input.balanceIn);
        assertEq(output.balanceOut, input.balanceOut);
    }

    function testQuoteAndSwapEntryPointsAreDeterministic() external {
        SwapQuery memory query = _query(address(vault), address(asset), true);
        SwapRegisters memory input = _registers(100e6, 5e18, 0);
        bytes memory config = _config(SPREAD, ASSET_UNIT, ASSET_UNIT);

        (uint256 quotePc, uint256 quoteChopped, SwapRegisters memory quoteRegisters) =
            IStaticExtruction(address(target)).extruction(true, 42, query, input, config, hex"abcd");
        (uint256 swapPc, uint256 swapChopped, SwapRegisters memory swapRegisters) =
            IExtruction(address(target)).extruction(false, 42, query, input, config, hex"abcd");

        assertEq(quotePc, 42);
        assertEq(quoteChopped, 0);
        assertEq(quotePc, swapPc);
        assertEq(quoteChopped, swapChopped);
        assertEq(quoteRegisters.amountIn, swapRegisters.amountIn);
        assertEq(quoteRegisters.amountOut, swapRegisters.amountOut);
    }

    function testDonationOutsideMakerBoundsReverts() external {
        bytes memory config = _config(SPREAD, 990_000, 1_010_000);
        asset.mint(address(vault), 100_000e6);
        (uint256 changedRate,,) = target.currentRate(address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, changedRate, 990_000, 1_010_000)
        );
        _quoteCurrent(_query(address(vault), address(asset), true), _registers(type(uint256).max, 1e18, 0), config);
    }

    function testUnsupportedPairReverts() external {
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                Vault4626Extruction.UnsupportedPair.selector,
                address(other),
                address(asset),
                address(vault),
                address(asset)
            )
        );
        _quoteCurrent(
            _query(address(other), address(asset), true),
            _registers(type(uint256).max, 1e18, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testInsufficientLiquidityReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InsufficientLiquidity.selector, 998_500, 1));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(1, 1e18, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testExactInputRejectsPrecomputedOutput() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, true, 1));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, 1e18, 1),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testExactOutputRejectsPrecomputedInput() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.RecomputeDetected.selector, false, 1));
        _quoteCurrent(
            _query(address(vault), address(asset), false),
            _registers(type(uint256).max, 1, 1e6),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testZeroExactInputReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroSpecifiedAmount.selector, true));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, 0, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testZeroExactOutputReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroSpecifiedAmount.selector, false));
        _quoteCurrent(
            _query(address(vault), address(asset), false),
            _registers(type(uint256).max, 0, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testTinyShareAmountThatRoundsToZeroReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.AmountRoundsToZero.selector, 1));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, 1, 0),
            _config(SPREAD, ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testRejectsInvalidSpread() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidSpread.selector, BPS));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, 1e18, 0),
            _config(uint16(BPS), ASSET_UNIT, ASSET_UNIT)
        );
    }

    function testRejectsInvalidBounds() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidBounds.selector, 0, ASSET_UNIT));
        _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, 1e18, 0),
            _config(SPREAD, 0, ASSET_UNIT)
        );
    }

    function testRejectsInvalidConfigLength() external {
        bytes memory shortConfig = new bytes(127);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidConfigLength.selector, 127, 128));
        _quoteCurrent(_query(address(vault), address(asset), true), _registers(type(uint256).max, 1e18, 0), shortConfig);
    }

    function testRejectsDirtyAddressPadding() external {
        bytes memory dirty = _config(SPREAD, ASSET_UNIT, ASSET_UNIT);
        assembly ("memory-safe") {
            mstore(add(dirty, 0x20), or(mload(add(dirty, 0x20)), shl(255, 1)))
        }
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteCurrent(_query(address(vault), address(asset), true), _registers(type(uint256).max, 1e18, 0), dirty);
    }

    function testRejectsDirtySpreadPadding() external {
        bytes memory dirty = _config(SPREAD, ASSET_UNIT, ASSET_UNIT);
        assembly ("memory-safe") {
            mstore(add(dirty, 0x40), or(mload(add(dirty, 0x40)), shl(255, 1)))
        }
        vm.expectRevert(Vault4626Extruction.MalformedConfig.selector);
        _quoteCurrent(_query(address(vault), address(asset), true), _registers(type(uint256).max, 1e18, 0), dirty);
    }

    function testRejectsAddressWithoutVaultCode() external {
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidVault.selector, address(1)));
        target.currentRate(address(1));
    }

    function testRejectsAssetWithoutCode() external {
        VaultStub badVault = new VaultStub(address(1), 18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidAsset.selector, address(1)));
        target.currentRate(address(badVault));
    }

    function testRejectsSelfReferentialVaultAsset() external {
        SelfReferentialVault badVault = new SelfReferentialVault();
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.SelfReferentialAsset.selector, address(badVault)));
        target.currentRate(address(badVault));
    }

    function testRejectsZeroRate() external {
        VaultStub zeroRateVault = new VaultStub(address(asset), 18, 0);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroVaultRate.selector, address(zeroRateVault)));
        target.currentRate(address(zeroRateVault));
    }

    function testRejectsUnsafeShareDecimals() external {
        VaultStub unsafeDecimals = new VaultStub(address(asset), 78, 1);
        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.InvalidShareDecimals.selector, 78));
        target.currentRate(address(unsafeDecimals));
    }

    function testStrategyEncodingForDeployedRouter() external view {
        bytes memory instruction =
            AquiferStrategy.buildV102(address(target), address(vault), SPREAD, ASSET_UNIT, ASSET_UNIT);

        assertEq(instruction.length, 150);
        assertEq(uint8(instruction[0]), 0x20);
        assertEq(uint8(instruction[1]), 0x94);
        assertEq(address(bytes20(_slice(instruction, 2, 20))), address(target));
    }

    function testStrategyEncodingForCurrentRouter() external view {
        bytes memory instruction =
            AquiferStrategy.buildCurrent(address(target), address(vault), SPREAD, ASSET_UNIT, ASSET_UNIT);

        assertEq(instruction.length, 150);
        assertEq(uint8(instruction[0]), 0x04);
        assertEq(uint8(instruction[1]), 0x94);
    }

    function testFuzzExactInputSharesToAssets(
        uint128 rawAmount,
        uint16 spread
    ) external view {
        uint256 amountIn = bound(uint256(rawAmount), SHARE_UNIT, 1_000_000e18);
        spread = uint16(bound(uint256(spread), 0, BPS - 1));

        SwapRegisters memory registers = _quoteCurrent(
            _query(address(vault), address(asset), true),
            _registers(type(uint256).max, amountIn, 0),
            _config(spread, ASSET_UNIT, ASSET_UNIT)
        );

        uint256 fairOut = amountIn * ASSET_UNIT / SHARE_UNIT;
        assertEq(registers.amountOut, fairOut * (BPS - spread) / BPS);
        assertLe(registers.amountOut, fairOut);
    }

    function testFuzzExactInputAssetsToShares(
        uint96 rawAmount,
        uint16 spread
    ) external view {
        uint256 amountIn = bound(uint256(rawAmount), ASSET_UNIT, 1_000_000e6);
        spread = uint16(bound(uint256(spread), 0, BPS - 1));

        SwapRegisters memory registers = _quoteCurrent(
            _query(address(asset), address(vault), true),
            _registers(type(uint256).max, amountIn, 0),
            _config(spread, ASSET_UNIT, ASSET_UNIT)
        );

        uint256 fairOut = amountIn * SHARE_UNIT / ASSET_UNIT;
        assertEq(registers.amountOut, fairOut * (BPS - spread) / BPS);
        assertLe(registers.amountOut, fairOut);
    }

    function _quoteCurrent(
        SwapQuery memory query,
        SwapRegisters memory registers,
        bytes memory config
    ) private view returns (SwapRegisters memory output) {
        (,, SwapRegisters memory result) =
            IStaticExtruction(address(target)).extruction(true, 31, query, registers, config, "");
        return result;
    }

    function _query(
        address tokenIn,
        address tokenOut,
        bool isExactIn
    ) private pure returns (SwapQuery memory) {
        return SwapQuery({
            orderHash: keccak256("aquifer-test"),
            maker: address(0xA11CE),
            taker: address(0xB0B),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: isExactIn
        });
    }

    function _registers(
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut
    ) private pure returns (SwapRegisters memory) {
        return
            SwapRegisters({
                balanceIn: type(uint256).max, balanceOut: balanceOut, amountIn: amountIn, amountOut: amountOut
            });
    }

    function _config(
        uint16 spread,
        uint256 minRate,
        uint256 maxRate
    ) private view returns (bytes memory) {
        return abi.encode(address(vault), spread, minRate, maxRate);
    }

    function _ceilDiv(
        uint256 numerator,
        uint256 denominator
    ) private pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }

    function _slice(
        bytes memory data,
        uint256 start,
        uint256 length
    ) private pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = data[start + i];
        }
    }
}

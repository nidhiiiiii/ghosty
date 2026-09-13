// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    IExtruction,
    IExtructionV102,
    IStaticExtruction,
    IStaticExtructionV102,
    SwapQuery,
    SwapRegisters,
    SwapRegistersV102
} from "./interfaces/ISwapVMExtruction.sol";

/// @title Vault4626Extruction
/// @notice Prices swaps between an ERC-4626 share and its asset at the vault's live conversion rate.
/// @dev One view implementation serves both quote (STATICCALL) and swap (CALL), so the two paths cannot branch.
///      Strategy args are `abi.encode(vault, spreadBps, minRate, maxRate)`.
///      Configured bounds must stay inside ±MAX_RATE_DEVIATION_BPS of the live rate.
contract Vault4626Extruction is IExtruction, IStaticExtruction, IExtructionV102, IStaticExtructionV102 {
    uint256 public constant BPS = 10_000;
    uint256 public constant CONFIG_LENGTH = 128;
    uint8 public constant MAX_SAFE_DECIMALS = 77;
    uint256 public constant MAX_RATE_DEVIATION_BPS = 100;
    uint256 public constant RATE_ROUNDTRIP_BPS = 10;

    error InvalidConfigLength(uint256 actual, uint256 expected);
    error MalformedConfig();
    error InvalidVault(address vault);
    error InvalidAsset(address asset);
    error SelfReferentialAsset(address vault);
    error InvalidSpread(uint256 spreadBps);
    error InvalidBounds(uint256 minRate, uint256 maxRate);
    error InvalidShareDecimals(uint8 decimals);
    error ZeroVaultRate(address vault);
    error RateOutOfBounds(uint256 rate, uint256 minRate, uint256 maxRate);
    error RateBandTooWide(uint256 minRate, uint256 maxRate, uint256 maxDeviationBps);
    error UnsupportedPair(address tokenIn, address tokenOut, address vault, address asset);
    error RecomputeDetected(bool isExactIn, uint256 populatedAmount);
    error ZeroSpecifiedAmount(bool isExactIn);
    error AmountRoundsToZero(uint256 specifiedAmount);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error Unauthorized(address caller);
    error VaultNotAllowlisted(address vault);
    error InconsistentVaultRate(address vault, uint256 sharesBack, uint256 shareUnit);

    struct Config {
        address vault;
        uint16 spreadBps;
        uint256 minRate;
        uint256 maxRate;
    }

    address public owner;
    bool public allowlistEnabled;
    mapping(address => bool) public allowedVaults;

    constructor() {
        owner = msg.sender;
    }

    function setAllowlistEnabled(
        bool enabled
    ) external {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        allowlistEnabled = enabled;
    }

    function setVaultAllowed(
        address vault,
        bool allowed
    ) external {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        if (vault == address(0)) revert InvalidVault(vault);
        allowedVaults[vault] = allowed;
    }

    /// @notice Current-main ABI. The function is deliberately view in both execution modes.
    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    )
        external
        view
        override(IExtruction, IStaticExtruction)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        _guardRecompute(query.isExactIn, swap.amountIn, swap.amountOut);
        (uint256 amountIn, uint256 amountOut) =
            _quote(query, swap.balanceIn, swap.balanceOut, swap.amountIn, swap.amountOut, args);

        updatedSwap = swap;
        updatedSwap.amountIn = amountIn;
        updatedSwap.amountOut = amountOut;
        return (nextPC, 0, updatedSwap);
    }

    /// @notice Tagged-v1.0.2 ABI. Fee accounting remains untouched.
    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegistersV102 calldata swap,
        bytes calldata args,
        bytes calldata
    )
        external
        view
        override(IExtructionV102, IStaticExtructionV102)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegistersV102 memory updatedSwap)
    {
        _guardRecompute(query.isExactIn, swap.amountIn, swap.amountOut);
        (uint256 amountIn, uint256 amountOut) =
            _quote(query, swap.balanceIn, swap.balanceOut, swap.amountIn, swap.amountOut, args);

        updatedSwap = swap;
        updatedSwap.amountIn = amountIn;
        updatedSwap.amountOut = amountOut;
        return (nextPC, 0, updatedSwap);
    }

    /// @notice Encodes the exact bytes expected after the Extruction target address.
    function encodeConfig(
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) external pure returns (bytes memory) {
        return abi.encode(vault, spreadBps, minRate, maxRate);
    }

    /// @notice Returns asset base units represented by one whole share token.
    function currentRate(
        address vault
    ) public view returns (uint256 rate, uint256 shareUnit, address asset) {
        if (vault == address(0) || vault.code.length == 0) revert InvalidVault(vault);
        if (allowlistEnabled && !allowedVaults[vault]) revert VaultNotAllowlisted(vault);

        IERC4626 vaultContract = IERC4626(vault);
        asset = vaultContract.asset();
        if (asset == address(0) || asset.code.length == 0) revert InvalidAsset(asset);
        if (asset == vault) revert SelfReferentialAsset(vault);

        try IERC20Metadata(asset).decimals() returns (uint8 assetDecimals) {
            if (assetDecimals > MAX_SAFE_DECIMALS) revert InvalidAsset(asset);
        } catch {
            revert InvalidAsset(asset);
        }

        uint8 shareDecimals = vaultContract.decimals();
        if (shareDecimals > MAX_SAFE_DECIMALS) revert InvalidShareDecimals(shareDecimals);

        shareUnit = 10 ** uint256(shareDecimals);
        rate = vaultContract.convertToAssets(shareUnit);
        if (rate == 0) revert ZeroVaultRate(vault);

        uint256 sharesBack = vaultContract.convertToShares(rate);
        uint256 lo = Math.mulDiv(shareUnit, BPS - RATE_ROUNDTRIP_BPS, BPS);
        uint256 hi = Math.mulDiv(shareUnit, BPS + RATE_ROUNDTRIP_BPS, BPS, Math.Rounding.Ceil);
        if (lo == 0) lo = 1;
        if (sharesBack < lo || sharesBack > hi) revert InconsistentVaultRate(vault, sharesBack, shareUnit);
    }

    function _quote(
        SwapQuery calldata query,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) private view returns (uint256 quotedAmountIn, uint256 quotedAmountOut) {
        Config memory config = _decodeConfig(args);
        if (config.spreadBps >= BPS) revert InvalidSpread(config.spreadBps);
        if (config.minRate == 0 || config.maxRate < config.minRate) {
            revert InvalidBounds(config.minRate, config.maxRate);
        }

        (uint256 rate, uint256 shareUnit, address asset) = currentRate(config.vault);
        if (rate < config.minRate || rate > config.maxRate) {
            revert RateOutOfBounds(rate, config.minRate, config.maxRate);
        }
        _guardRateBand(rate, config.minRate, config.maxRate);

        bool sharesIn;
        if (query.tokenIn == config.vault && query.tokenOut == asset) {
            sharesIn = true;
        } else if (query.tokenIn == asset && query.tokenOut == config.vault) {
            sharesIn = false;
        } else {
            revert UnsupportedPair(query.tokenIn, query.tokenOut, config.vault, asset);
        }

        uint256 keptBps = BPS - config.spreadBps;
        if (query.isExactIn) {
            uint256 fairAmountOut =
                sharesIn ? Math.mulDiv(amountIn, rate, shareUnit) : Math.mulDiv(amountIn, shareUnit, rate);
            quotedAmountIn = amountIn;
            quotedAmountOut = Math.mulDiv(fairAmountOut, keptBps, BPS);
            if (amountIn != 0 && quotedAmountOut == 0) revert AmountRoundsToZero(amountIn);
        } else {
            uint256 fairAmountOut = Math.mulDiv(amountOut, BPS, keptBps, Math.Rounding.Ceil);
            quotedAmountIn = sharesIn
                ? Math.mulDiv(fairAmountOut, shareUnit, rate, Math.Rounding.Ceil)
                : Math.mulDiv(fairAmountOut, rate, shareUnit, Math.Rounding.Ceil);
            quotedAmountOut = amountOut;
            if (amountOut != 0 && quotedAmountIn == 0) revert AmountRoundsToZero(amountOut);
        }

        if (quotedAmountOut > balanceOut) {
            revert InsufficientLiquidity(quotedAmountOut, balanceOut);
        }
        if (quotedAmountIn > balanceIn) {
            revert InsufficientLiquidity(quotedAmountIn, balanceIn);
        }
    }

    function _guardRateBand(
        uint256 rate,
        uint256 minRate,
        uint256 maxRate
    ) private pure {
        uint256 floorMin = Math.mulDiv(rate, BPS - MAX_RATE_DEVIATION_BPS, BPS);
        if (minRate < floorMin) revert RateBandTooWide(minRate, maxRate, MAX_RATE_DEVIATION_BPS);

        uint256 maxRise = Math.mulDiv(rate, MAX_RATE_DEVIATION_BPS, BPS, Math.Rounding.Ceil);
        if (maxRate - rate > maxRise) revert RateBandTooWide(minRate, maxRate, MAX_RATE_DEVIATION_BPS);
    }

    function _decodeConfig(
        bytes calldata args
    ) private pure returns (Config memory config) {
        if (args.length != CONFIG_LENGTH) revert InvalidConfigLength(args.length, CONFIG_LENGTH);

        uint256 vaultWord;
        uint256 spreadWord;
        assembly ("memory-safe") {
            vaultWord := calldataload(args.offset)
            spreadWord := calldataload(add(args.offset, 0x20))
            mstore(add(config, 0x40), calldataload(add(args.offset, 0x40)))
            mstore(add(config, 0x60), calldataload(add(args.offset, 0x60)))
        }
        // Reject dirty ABI padding explicitly instead of surfacing an opaque decoder revert.
        if (vaultWord >> 160 != 0 || spreadWord >> 16 != 0) revert MalformedConfig();
        config.vault = address(uint160(vaultWord));
        config.spreadBps = uint16(spreadWord);
    }

    function _guardRecompute(
        bool isExactIn,
        uint256 amountIn,
        uint256 amountOut
    ) private pure {
        uint256 specifiedAmount = isExactIn ? amountIn : amountOut;
        if (specifiedAmount == 0) revert ZeroSpecifiedAmount(isExactIn);

        uint256 populatedAmount = isExactIn ? amountOut : amountIn;
        if (populatedAmount != 0) revert RecomputeDetected(isExactIn, populatedAmount);
    }
}

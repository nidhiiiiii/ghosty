// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice ERC-4626-shaped vault whose conversion rate is set directly, so rounding can be pinned exactly.
/// @dev `convertToAssets(10 ** decimals()) == ratePerShareUnit` by construction.
contract RateVault {
    address public asset;
    uint8 public decimals;
    uint256 public ratePerShareUnit;

    constructor(
        address asset_,
        uint8 decimals_,
        uint256 ratePerShareUnit_
    ) {
        asset = asset_;
        decimals = decimals_;
        ratePerShareUnit = ratePerShareUnit_;
    }

    function setAsset(
        address asset_
    ) external {
        asset = asset_;
    }

    function setDecimals(
        uint8 decimals_
    ) external {
        decimals = decimals_;
    }

    function setRate(
        uint256 ratePerShareUnit_
    ) external {
        ratePerShareUnit = ratePerShareUnit_;
    }

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256) {
        uint256 shareUnit = 10 ** uint256(decimals);
        if (shares == shareUnit) return ratePerShareUnit;
        return Math.mulDiv(shares, ratePerShareUnit, shareUnit);
    }

    function convertToShares(
        uint256 assets
    ) external view returns (uint256) {
        return Math.mulDiv(assets, 10 ** uint256(decimals), ratePerShareUnit);
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Vault whose `asset()` points back at itself, collapsing the share/asset pair into one token.
contract SelfAssetVault {
    uint8 public constant decimals = 18;

    function asset() external view returns (address) {
        return address(this);
    }

    function convertToAssets(
        uint256 shares
    ) external pure returns (uint256) {
        return shares * 2;
    }
}

/// @notice Vault with individually armed reverts on each accessor the Extruction reads.
contract RevertingVault {
    enum Mode {
        None,
        AssetReverts,
        DecimalsReverts,
        ConvertReverts
    }

    Mode public mode;
    address public underlying;

    constructor(
        address underlying_,
        Mode mode_
    ) {
        underlying = underlying_;
        mode = mode_;
    }

    error VaultBoom();

    function asset() external view returns (address) {
        if (mode == Mode.AssetReverts) revert VaultBoom();
        return underlying;
    }

    function decimals() external view returns (uint8) {
        if (mode == Mode.DecimalsReverts) revert VaultBoom();
        return 18;
    }

    function convertToAssets(
        uint256
    ) external view returns (uint256) {
        if (mode == Mode.ConvertReverts) revert VaultBoom();
        return 1e18;
    }
}

/// @notice Vault returning raw words that do not fit the declared ABI types.
/// @dev Used to prove how the Extruction behaves against non-conforming vaults.
contract RawReturnVault {
    bytes private _assetReturn;
    bytes private _decimalsReturn;
    bytes private _convertReturn;

    constructor(
        bytes memory assetReturn,
        bytes memory decimalsReturn,
        bytes memory convertReturn
    ) {
        _assetReturn = assetReturn;
        _decimalsReturn = decimalsReturn;
        _convertReturn = convertReturn;
    }

    // solhint-disable-next-line no-complex-fallback
    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        bytes4 sel = bytes4(data[:4]);
        if (sel == bytes4(keccak256("asset()"))) return _assetReturn;
        if (sel == bytes4(keccak256("decimals()"))) return _decimalsReturn;
        if (sel == bytes4(keccak256("convertToAssets(uint256)"))) return _convertReturn;
        revert("RawReturnVault: unexpected selector");
    }
}

/// @notice Token-shaped contract with no behaviour, used purely to occupy an address that has code.
contract CodeStub {
    uint256 private _slot;

    function poke() external {
        _slot += 1;
    }
}

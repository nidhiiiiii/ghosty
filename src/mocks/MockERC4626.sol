// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Local-only vault with configurable share/asset decimal offset.
contract MockERC4626 is ERC4626 {
    uint8 private immutable _OFFSET;

    constructor(
        IERC20 asset_,
        uint8 decimalsOffset_
    ) ERC20("Aquifer Demo Vault", "aqV") ERC4626(asset_) {
        _OFFSET = decimalsOffset_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _OFFSET;
    }
}

// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Demo token whose minting is restricted to the deployer.
contract MockERC20 is ERC20 {
    uint8 private immutable _TOKEN_DECIMALS;
    address public immutable minter;

    error Unauthorized(address caller);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _TOKEN_DECIMALS = decimals_;
        minter = msg.sender;
    }

    function decimals() public view override returns (uint8) {
        return _TOKEN_DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        if (msg.sender != minter) revert Unauthorized(msg.sender);
        _mint(to, amount);
    }
}

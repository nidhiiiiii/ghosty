// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Vault4626Extruction} from "../../src/Vault4626Extruction.sol";
import {
    IExtruction,
    IExtructionV102,
    IStaticExtruction,
    IStaticExtructionV102,
    SwapQuery,
    SwapRegisters,
    SwapRegistersV102
} from "../../src/interfaces/ISwapVMExtruction.sol";

/// @notice Shared fixtures and call helpers for the Aquifer Extruction suite.
abstract contract AquiferTestBase is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEFAULT_PC = 7;

    /// @dev Mirrors the two register layouts so assertions can be written once.
    struct Result {
        uint256 nextPC;
        uint256 choppedLength;
        uint256 balanceIn;
        uint256 balanceOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 amountNetPulled;
    }

    Vault4626Extruction internal ext;

    function setUp() public virtual {
        ext = new Vault4626Extruction();
    }

    /*//////////////////////////////////////////////////////////////
                              INPUT BUILDERS
    //////////////////////////////////////////////////////////////*/

    function query(
        address tokenIn,
        address tokenOut,
        bool isExactIn
    ) internal pure returns (SwapQuery memory q) {
        q.orderHash = keccak256("aquifer.order");
        q.maker = address(uint160(uint256(keccak256("aquifer.maker"))));
        q.taker = address(uint160(uint256(keccak256("aquifer.taker"))));
        q.tokenIn = tokenIn;
        q.tokenOut = tokenOut;
        q.isExactIn = isExactIn;
    }

    /// @notice Registers as SwapVM presents them: only the taker-specified side is populated.
    function registers(
        bool isExactIn,
        uint256 specifiedAmount,
        uint256 balanceIn,
        uint256 balanceOut
    ) internal pure returns (SwapRegisters memory r) {
        r.balanceIn = balanceIn;
        r.balanceOut = balanceOut;
        if (isExactIn) {
            r.amountIn = specifiedAmount;
        } else {
            r.amountOut = specifiedAmount;
        }
    }

    /// @notice Registers with both amount fields set explicitly, for recompute-guard probing.
    function registersRaw(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (SwapRegisters memory r) {
        r.balanceIn = balanceIn;
        r.balanceOut = balanceOut;
        r.amountIn = amountIn;
        r.amountOut = amountOut;
    }

    function registersRawV102(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) internal pure returns (SwapRegistersV102 memory r) {
        r.balanceIn = balanceIn;
        r.balanceOut = balanceOut;
        r.amountIn = amountIn;
        r.amountOut = amountOut;
        r.amountNetPulled = amountNetPulled;
    }

    function registersV102(
        bool isExactIn,
        uint256 specifiedAmount,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountNetPulled
    ) internal pure returns (SwapRegistersV102 memory r) {
        r.balanceIn = balanceIn;
        r.balanceOut = balanceOut;
        r.amountNetPulled = amountNetPulled;
        if (isExactIn) {
            r.amountIn = specifiedAmount;
        } else {
            r.amountOut = specifiedAmount;
        }
    }

    function config(
        address vault,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal pure returns (bytes memory) {
        return abi.encode(vault, spreadBps, minRate, maxRate);
    }

    /// @notice Builds config bytes from raw words so dirty padding and wrong lengths can be injected.
    function rawConfig(
        uint256 w0,
        uint256 w1,
        uint256 w2,
        uint256 w3
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(w0, w1, w2, w3);
    }

    /*//////////////////////////////////////////////////////////////
                              CALL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Quote path: STATICCALL into the view interface, exactly as SwapVM quoting does.
    function quoteCurrent(
        SwapQuery memory q,
        SwapRegisters memory r,
        bytes memory args
    ) internal view returns (Result memory out) {
        (uint256 pc, uint256 chopped, SwapRegisters memory updated) =
            IStaticExtruction(address(ext)).extruction(true, DEFAULT_PC, q, r, args, "");
        out = Result(pc, chopped, updated.balanceIn, updated.balanceOut, updated.amountIn, updated.amountOut, 0);
    }

    /// @notice Swap path: CALL into the mutable interface, exactly as SwapVM filling does.
    function swapCurrent(
        SwapQuery memory q,
        SwapRegisters memory r,
        bytes memory args
    ) internal returns (Result memory out) {
        (uint256 pc, uint256 chopped, SwapRegisters memory updated) =
            IExtruction(address(ext)).extruction(false, DEFAULT_PC, q, r, args, "");
        out = Result(pc, chopped, updated.balanceIn, updated.balanceOut, updated.amountIn, updated.amountOut, 0);
    }

    function quoteV102(
        SwapQuery memory q,
        SwapRegistersV102 memory r,
        bytes memory args
    ) internal view returns (Result memory out) {
        (uint256 pc, uint256 chopped, SwapRegistersV102 memory updated) =
            IStaticExtructionV102(address(ext)).extruction(true, DEFAULT_PC, q, r, args, "");
        out = Result(
            pc,
            chopped,
            updated.balanceIn,
            updated.balanceOut,
            updated.amountIn,
            updated.amountOut,
            updated.amountNetPulled
        );
    }

    function swapV102(
        SwapQuery memory q,
        SwapRegistersV102 memory r,
        bytes memory args
    ) internal returns (Result memory out) {
        (uint256 pc, uint256 chopped, SwapRegistersV102 memory updated) =
            IExtructionV102(address(ext)).extruction(false, DEFAULT_PC, q, r, args, "");
        out = Result(
            pc,
            chopped,
            updated.balanceIn,
            updated.balanceOut,
            updated.amountIn,
            updated.amountOut,
            updated.amountNetPulled
        );
    }

    /*//////////////////////////////////////////////////////////////
                             ASSERTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot convenience: quote a single leg through the current layout with generous liquidity.
    function priceCurrent(
        address vault,
        address asset,
        bool sharesIn,
        bool isExactIn,
        uint256 specifiedAmount,
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate,
        uint256 balanceOut
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = sharesIn ? (vault, asset) : (asset, vault);
        Result memory r = quoteCurrent(
            query(tokenIn, tokenOut, isExactIn),
            registers(isExactIn, specifiedAmount, type(uint256).max, balanceOut),
            config(vault, spreadBps, minRate, maxRate)
        );
        return (r.amountIn, r.amountOut);
    }

    function assertRegistersUntouched(
        Result memory r,
        uint256 balanceIn,
        uint256 balanceOut
    ) internal pure {
        assertEq(r.nextPC, DEFAULT_PC, "nextPC must pass through unchanged");
        assertEq(r.choppedLength, 0, "choppedLength must be zero; no takerData is consumed");
        assertEq(r.balanceIn, balanceIn, "balanceIn must not be rewritten");
        assertEq(r.balanceOut, balanceOut, "balanceOut must not be rewritten");
    }
}

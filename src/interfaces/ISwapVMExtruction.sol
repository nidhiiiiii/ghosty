// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @notice Read-only swap context used by SwapVM.
/// @dev Layout verified against 1inch/swap-vm main at
///      afd99c408b4ed610027f4426c6f98650acac9f5f.
struct SwapQuery {
    bytes32 orderHash;
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    bool isExactIn;
}

/// @notice Current SwapVM register layout.
struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
}

/// @notice Swap-path interface in the current SwapVM source.
interface IExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap);
}

/// @notice Quote-path interface in the current SwapVM source.
interface IStaticExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap);
}

/// @notice Register layout used by tagged SwapVM v1.0.2 and the documented deployed-router family.
/// @dev This layout includes the fee-accounting register removed from current main.
struct SwapRegistersV102 {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 amountNetPulled;
}

/// @notice Swap-path interface used by tagged SwapVM v1.0.2.
interface IExtructionV102 {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegistersV102 calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegistersV102 memory updatedSwap);
}

/// @notice Quote-path interface used by tagged SwapVM v1.0.2.
interface IStaticExtructionV102 {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegistersV102 calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegistersV102 memory updatedSwap);
}

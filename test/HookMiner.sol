// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookMiner
/// @notice Test utility for mining CREATE2 salts that produce hook addresses
///         with specific V4 permission bits set in the lowest 14 bits.
/// @dev    Only for use in Foundry tests — pure functions loop until a valid
///         salt is found. In practice a valid salt is found within thousands
///         of iterations so runtime is negligible.
library HookMiner {
    /// @dev Mask covering all 14 V4 hook permission flag bits (bits 0–13).
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Find a CREATE2 salt such that the resulting deployed address has
    ///         exactly `targetMask` set in its low 14 bits — no more, no less.
    ///         Use this for sub-hooks that only implement a subset of callbacks.
    ///
    /// @param deployer    The address that will call CREATE2 (e.g. the Foundry
    ///                    Create2Deployer factory, not msg.sender of the script).
    /// @param initCode    abi.encodePacked(creationCode, abi.encode(constructorArgs))
    /// @param targetMask  Bitmask of the exact permission bits required.
    ///                    Build it with permissionsToMask() or compose manually
    ///                    from Hooks.*_FLAG constants.
    function findSaltForMask(
        address deployer,
        bytes memory initCode,
        uint160 targetMask
    ) internal pure returns (uint256 salt) {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            address predicted = computeCreate2Address(
                i,
                initCodeHash,
                deployer
            );
            if (uint160(predicted) & ALL_HOOK_MASK == targetMask) {
                return i;
            }
        }
        revert("HookMiner: no valid salt found");
    }

    /// @notice Converts a Hooks.Permissions struct into the uint160 bitmask
    ///         that V4 encodes in the hook address.
    ///
    ///         Bit layout (matches Hooks.sol):
    ///           bit 13 BEFORE_INITIALIZE
    ///           bit 12 AFTER_INITIALIZE
    ///           bit 11 BEFORE_ADD_LIQUIDITY
    ///           bit 10 AFTER_ADD_LIQUIDITY
    ///           bit  9 BEFORE_REMOVE_LIQUIDITY
    ///           bit  8 AFTER_REMOVE_LIQUIDITY
    ///           bit  7 BEFORE_SWAP
    ///           bit  6 AFTER_SWAP
    ///           bit  5 BEFORE_DONATE
    ///           bit  4 AFTER_DONATE
    ///           bit  3 BEFORE_SWAP_RETURNS_DELTA
    ///           bit  2 AFTER_SWAP_RETURNS_DELTA
    ///           bit  1 AFTER_ADD_LIQUIDITY_RETURNS_DELTA
    ///           bit  0 AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA
    ///
    ///         Usage in a miner script:
    ///           uint160 mask = HookMiner.permissionsToMask(hook.getHookPermissions());
    ///           uint256 salt = HookMiner.findSaltForMask(CREATE2_FACTORY, initCode, mask);
    function permissionsToMask(
        bool beforeInitialize,
        bool afterInitialize,
        bool beforeAddLiquidity,
        bool afterAddLiquidity,
        bool beforeRemoveLiquidity,
        bool afterRemoveLiquidity,
        bool beforeSwap,
        bool afterSwap,
        bool beforeDonate,
        bool afterDonate,
        bool beforeSwapReturnDelta,
        bool afterSwapReturnDelta,
        bool afterAddLiquidityReturnDelta,
        bool afterRemoveLiquidityReturnDelta
    ) internal pure returns (uint160 mask) {
        if (beforeInitialize) mask |= uint160(1 << 13);
        if (afterInitialize) mask |= uint160(1 << 12);
        if (beforeAddLiquidity) mask |= uint160(1 << 11);
        if (afterAddLiquidity) mask |= uint160(1 << 10);
        if (beforeRemoveLiquidity) mask |= uint160(1 << 9);
        if (afterRemoveLiquidity) mask |= uint160(1 << 8);
        if (beforeSwap) mask |= uint160(1 << 7);
        if (afterSwap) mask |= uint160(1 << 6);
        if (beforeDonate) mask |= uint160(1 << 5);
        if (afterDonate) mask |= uint160(1 << 4);
        if (beforeSwapReturnDelta) mask |= uint160(1 << 3);
        if (afterSwapReturnDelta) mask |= uint160(1 << 2);
        if (afterAddLiquidityReturnDelta) mask |= uint160(1 << 1);
        if (afterRemoveLiquidityReturnDelta) mask |= uint160(1 << 0);
    }

    /// @notice Computes the CREATE2 address for a given salt, initCodeHash, and deployer.
    function computeCreate2Address(
        uint256 salt,
        bytes32 initCodeHash,
        address deployer
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xFF),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }
}

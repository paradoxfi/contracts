// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEpochModel
/// @notice Interface that every epoch model must implement.
///
/// EpochManager holds a mapping from poolId → address(IEpochModel) and calls
/// through this interface exclusively. Concrete models (FixedDateEpochModel,
/// RollingEpochModel, …) are registered per-pool at initialisation time and
/// can be swapped by governance without redeploying any core contract.
///
/// Implementing contracts MUST be stateless with respect to individual pools.
/// All pool-specific state lives in EpochManager; the model is a pure strategy
/// object — it receives parameters and returns computed values.
interface IEpochModel {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when modelParams cannot be decoded into the expected shape.
    error InvalidModelParams();

    /// @notice Thrown when a computed maturity would be in the past or equal to
    ///         the start time (i.e. a zero-duration epoch).
    error InvalidMaturity(uint64 startTime, uint64 maturity);

    // -------------------------------------------------------------------------
    // Core lifecycle
    // -------------------------------------------------------------------------

    /// @notice Compute the maturity timestamp for a new epoch.
    ///
    /// Called by EpochManager.openEpoch() every time a new epoch is created for
    /// a pool that uses this model. The model must return a timestamp strictly
    /// greater than `startTime`.
    ///
    /// @param startTime   block.timestamp at the moment the epoch opens.
    /// @param modelParams ABI-encoded, model-specific configuration. Each model
    ///                    defines its own parameter struct and decodes it here.
    ///                    For FixedDateEpochModel this is `abi.encode(uint32 duration)`.
    ///                    For a future RollingEpochModel this could encode a window
    ///                    boundary strategy. EpochManager stores this blob and
    ///                    passes it through unchanged.
    /// @return maturity   Unix timestamp (seconds) when this epoch may be settled.
    function computeMaturity(uint64 startTime, bytes calldata modelParams)
        external
        view
        returns (uint64 maturity);

    /// @notice Whether epochs under this model should automatically open a
    ///         successor epoch immediately after settlement.
    ///
    /// EpochManager.settle() checks this flag after finalising an epoch. When
    /// true it calls openEpoch() again without waiting for an external trigger.
    ///
    /// FixedDateEpochModel returns false — each epoch is discrete and a new one
    /// must be opened explicitly (or by governance).
    /// RollingEpochModel (future) returns true — perpetual rolling windows.
    ///
    /// @return autoRoll true if the model wants continuous epoch succession.
    function shouldAutoRoll() external view returns (bool autoRoll);

    // -------------------------------------------------------------------------
    // Introspection
    // -------------------------------------------------------------------------

    /// @notice Short human-readable identifier for this model type.
    ///
    /// Used by off-chain indexers and the metadata URI builder in FYToken to
    /// describe what kind of epoch a given FYT belongs to.
    /// Examples: "FIXED_DATE", "ROLLING_WEEKLY"
    ///
    /// @return identifier A short ASCII string packed into bytes32.
    function modelType() external pure returns (bytes32 identifier);

    /// @notice Decode and validate a raw modelParams blob without creating an epoch.
    ///
    /// Called by EpochManager.registerPool() before the first epoch is opened so
    /// that misconfigured params are rejected at registration rather than silently
    /// producing a broken epoch later.
    ///
    /// @param modelParams The ABI-encoded params blob to validate.
    /// @return valid      true if the params are well-formed for this model.
    function validateParams(bytes calldata modelParams)
        external
        view
        returns (bool valid);

    /// @notice Human-readable description of what modelParams should contain.
    ///
    /// Purely informational — for tooling, front-ends, and ARCHITECTURE.md.
    /// Does not affect any on-chain behaviour.
    ///
    /// @return description A plain-English description of the params ABI encoding.
    function paramsDescription() external pure returns (string memory description);
}

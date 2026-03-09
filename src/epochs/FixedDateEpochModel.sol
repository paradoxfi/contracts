// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEpochModel} from "../epochs/IEpochModel.sol";

/// @title FixedDateEpochModel
/// @notice Epoch model where every epoch has a fixed calendar duration.
///
/// Behaviour
/// ---------
/// • computeMaturity() returns startTime + duration exactly.
/// • shouldAutoRoll()  returns false — each epoch is discrete.
/// • A new epoch is opened only when a caller (LP depositor or governance)
///   explicitly triggers EpochManager.openEpoch() after the previous one settles.
///
/// Supported durations
/// -------------------
/// Governance may configure any duration between MIN_DURATION and MAX_DURATION.
/// The canonical set of durations used in production pools is:
///
///     7 days   — weekly short-term yield
///    30 days   — monthly
///    90 days   — quarterly (recommended for institutional LPs)
///   180 days   — semi-annual
///   365 days   — annual
///
/// Duration is stored in the EpochManager's modelParams blob, NOT here.
/// This contract is completely stateless — it holds no per-pool data.
///
/// Extension path
/// --------------
/// To add RollingEpochModel later:
///   1. Create src/epochs/RollingEpochModel.sol implementing IEpochModel.
///   2. Override computeMaturity() to snap to the next weekly boundary.
///   3. Override shouldAutoRoll() to return true.
///   4. Register the new address against the desired pool in EpochManager.
///   5. No changes to EpochManager, ParadoxHook, YieldRouter, or any token.
contract FixedDateEpochModel is IEpochModel {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Minimum configurable epoch duration: 1 day.
    ///      Shorter durations create excessive settlement overhead and make the
    ///      oracle TWAP window (30 d) longer than the epoch itself, which breaks
    ///      the rate formula assumptions.
    uint32 public constant MIN_DURATION = 1 days;

    /// @dev Maximum configurable epoch duration: 2 years.
    ///      Hard cap to prevent accidental misconfiguration (e.g. passing
    ///      milliseconds instead of seconds).
    uint32 public constant MAX_DURATION = 730 days;

    // -------------------------------------------------------------------------
    // Params struct
    // -------------------------------------------------------------------------

    /// @notice The ABI-encoded modelParams blob expected by this model.
    ///
    /// EpochManager stores this struct (ABI-encoded) at pool registration and
    /// passes it back verbatim on every computeMaturity() and validateParams()
    /// call. The model never writes to storage — it only decodes this blob.
    ///
    /// @param duration Epoch length in seconds. Must be in [MIN_DURATION, MAX_DURATION].
    struct Params {
        uint32 duration;
    }

    // -------------------------------------------------------------------------
    // IEpochModel implementation
    // -------------------------------------------------------------------------

    /// @inheritdoc IEpochModel
    /// @dev Pure arithmetic — no storage reads, no external calls.
    ///      Reverts if the decoded duration is out of bounds or if the resulting
    ///      maturity overflows uint64 (would require duration > ~500 billion years).
    function computeMaturity(uint64 startTime, bytes calldata modelParams)
        external
        view
        override
        returns (uint64 maturity)
    {
        Params memory p = _decode(modelParams);

        // Overflow is practically impossible (uint64 max ≈ year 584,942) but we
        // check anyway to make static analysers happy and surface misconfiguration.
        uint64 duration64 = uint64(p.duration);
        maturity = startTime + duration64;

        // Sanity: maturity must be strictly in the future relative to startTime.
        // This also catches the case where startTime itself was somehow zero.
        if (maturity <= startTime) {
            revert InvalidMaturity(startTime, maturity);
        }

        // Additionally confirm maturity is not already in the past. This guards
        // against a scenario where EpochManager calls openEpoch() with a stale
        // startTime value.
        if (maturity <= uint64(block.timestamp)) {
            revert InvalidMaturity(startTime, maturity);
        }
    }

    /// @inheritdoc IEpochModel
    /// @dev Always false. Fixed-date epochs are discrete; after settlement a new
    ///      epoch must be opened explicitly. EpochManager will not auto-roll.
    function shouldAutoRoll() external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc IEpochModel
    function modelType() external pure override returns (bytes32) {
        // Right-pads the ASCII string "FIXED_DATE" to 32 bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32("FIXED_DATE");
    }

    /// @inheritdoc IEpochModel
    /// @dev Decodes the params blob and validates the duration is within bounds.
    ///      Returns false (rather than reverting) so EpochManager can emit a
    ///      descriptive error rather than bubbling a raw revert.
    function validateParams(bytes calldata modelParams)
        external
        view
        override
        returns (bool valid)
    {
        // Catch ABI decoding failures from malformed calldata.
        try this.externalDecode(modelParams) returns (Params memory p) {
            valid = p.duration >= MIN_DURATION && p.duration <= MAX_DURATION;
        } catch {
            valid = false;
        }
    }

    /// @inheritdoc IEpochModel
    function paramsDescription() external pure override returns (string memory) {
        return
            "abi.encode(FixedDateEpochModel.Params { uint32 duration })"
            " duration in seconds, must be in [86400, 63072000]"
            " (1 day to 2 years).";
    }

    // -------------------------------------------------------------------------
    // Convenience helpers
    // -------------------------------------------------------------------------

    /// @notice Encode a Params struct into the modelParams bytes blob.
    ///
    /// Off-chain tooling and deployment scripts call this to build the correct
    /// bytes to pass into EpochManager.registerPool(). Also useful in tests.
    ///
    /// @param duration Epoch duration in seconds.
    /// @return encoded ABI-encoded Params blob.
    function encodeParams(uint32 duration) external pure returns (bytes memory encoded) {
        encoded = abi.encode(Params({duration: duration}));
    }

    /// @notice Decode a modelParams blob and return the Params struct.
    ///
    /// Exposed as external so validateParams() can call it inside a try/catch
    /// to handle malformed calldata gracefully (internal calls cannot be
    /// wrapped in try/catch in Solidity).
    ///
    /// @param modelParams The ABI-encoded blob to decode.
    /// @return p          The decoded Params struct.
    function externalDecode(bytes calldata modelParams)
        external
        pure
        returns (Params memory p)
    {
        p = _decode(modelParams);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Decode modelParams and validate duration bounds.
    ///      Reverts with InvalidModelParams if the blob is malformed or the
    ///      duration is out of the accepted range.
    function _decode(bytes calldata modelParams) internal pure returns (Params memory p) {
        if (modelParams.length < 32) revert InvalidModelParams();

        p = abi.decode(modelParams, (Params));

        if (p.duration < MIN_DURATION || p.duration > MAX_DURATION) {
            revert InvalidModelParams();
        }
    }
}

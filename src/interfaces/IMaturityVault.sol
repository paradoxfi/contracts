// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMaturityVault {
    function receiveSettlement(
        uint256 epochId,
        address token,
        uint128 fytTotal,
        uint128 vytTotal
    ) external;

    function redeemFYT(uint256 epochId) external;

    function redeemVYT(uint256 epochId, uint256 positionId) external;

    function previewFYTPayout(uint256 epochId, address holder) external view;

    function previewVYTPayout(
        uint256 epochId,
        uint256 positionId
    ) external view;
}

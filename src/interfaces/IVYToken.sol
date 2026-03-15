// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVYToken
/// @notice Minimal interface for the VYT ERC-1155 token.
///         VYT is position-unique: each positionId has at most 1 token.
interface IVYToken {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function burn(address account, uint256 id, uint256 amount) external;
}
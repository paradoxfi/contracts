// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/// @title IFYToken
/// @notice Minimal interface for the FYT ERC-1155 token that MaturityVault
///         needs: balance query, total supply snapshot, and burn on redemption.
interface IFYToken {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function burn(address account, uint256 id, uint256 amount) external;
}
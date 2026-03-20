// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IntegrationBase.sol";

/// @title DeficitScenariosTest
/// @notice Integration tests for all three YieldRouter coverage zones.
///
/// Zone A — fees ≥ obligation: FYT paid in full, VYT gets surplus
/// Zone B — fees + buffer ≥ obligation: buffer rescues FYT, VYT gets nothing
/// Zone C — fees + buffer < obligation: FYT haircut, VYT gets nothing
///
/// Architecture notes (post-refactor):
///   - No PositionManager or _mintTokens — FYT+VYT minted atomically by hook.
///   - positionId captured from PositionOpened event via _addLiquidity.
///   - redeemFYT(positionId, KEY) / redeemVYT(positionId, KEY).
///   - Settlement.fytPositionCount replaces old fytSupplyAtSettle.
///   - Fee payout = trancheTotal / positionCount (equal per position).
contract DeficitScenariosTest is IntegrationBase {

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Settle and finalize with an explicit obligation override.
    function _settleWithObligation(uint128 obligation)
        internal
        returns (uint256 epochId, YieldRouter.SettlementAmounts memory amounts)
    {
        epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        vm.warp(ep.maturity);

        vm.prank(KEEPER);
        em.settle(epochId, GENESIS_TWAP, 0, 0);

        vm.prank(OWNER);
        yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        amounts = yr.finalizeEpoch(epochId, POOL, address(token0), obligation);
        vm.prank(OWNER);
        yr.setAuthorizedCaller(HOOK_ADDR);
        // receiveSettlement called internally by finalizeEpoch.
    }

    /// Directly ingest `fees` into YieldRouter against `obligation`.
    /// Grants KEEPER authorizedCaller temporarily.
    function _ingest(uint128 fees, uint128 obligation) internal {
        uint256 epochId = em.activeEpochIdFor(POOL);
        token0.mint(address(yr), fees);
        vm.prank(OWNER);
        yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), fees, obligation);
        vm.prank(OWNER);
        yr.setAuthorizedCaller(HOOK_ADDR);
    }

    /// Seed buffer by ingesting fees with zero obligation so all surplus skims.
    /// bufferTarget = fees × 10% → fees = bufferTarget × 10.
    function _seedBuffer(uint128 bufferTarget) internal {
        _ingest(uint128(uint256(bufferTarget) * 10), 0);
    }

    /// Seed oracle with n observations so openNextEpoch doesn't revert.
    function _seedOracle(uint16 n) internal {
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(OWNER);
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(3);
        for (uint16 i = 0; i < n; i++) {
            vm.warp(block.timestamp + 4 hours);
            vm.prank(OWNER);
            oracle.record(POOL, 10e18, 1_000_000e18);
        }
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(HOOK_ADDR);
    }

    // =========================================================================
    // Zone A — full coverage
    // =========================================================================

    function test_zoneA_fytPaidInFull() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(300e18, obligation); // 3× surplus → Zone A

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      0,          "must be Zone A");
        assertEq(amounts.fytAmount, obligation, "FYT must equal full obligation");
        assertGt(amounts.vytAmount, 0,          "VYT must receive surplus");
    }

    function test_zoneA_vytReceivesSurplus() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(200e18, obligation); // 100e18 surplus

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        // surplus = 100e18, skim = 10e18 (10%), variable = 90e18
        assertEq(amounts.vytAmount, 90e18);
    }

    function test_zoneA_bufferGrowsFromSkim() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        uint128 bufBefore  = yr.getReserveBuffer(POOL);
        _ingest(200e18, obligation);

        _settleWithObligation(obligation);

        // skim = 10% of 100e18 surplus = 10e18
        assertEq(yr.getReserveBuffer(POOL), bufBefore + 10e18);
    }

    function test_zoneA_fytHolderReceivesFullFeePayout() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(200e18, obligation);

        (uint256 epochId,) = _settleWithObligation(obligation);

        // 1 position → full fytTotal = obligation.
        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);
        assertEq(token0.balanceOf(LP_A) - balBefore, obligation);
    }

    function test_zoneA_vytHolderReceivesSurplus() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(200e18, obligation); // vytTotal = 90e18

        _settleWithObligation(obligation);

        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemVYT(LP_A, pid);
        assertEq(token0.balanceOf(LP_A) - balBefore, 90e18);
    }

    // =========================================================================
    // Zone B — buffer rescue
    // =========================================================================

    function test_zoneB_bufferCoversShortfall() public {
        _addLiquidity(LP_A, 1_000_000e18);

        _seedBuffer(50e18);
        assertEq(yr.getReserveBuffer(POOL), 50e18);

        uint128 obligation = 100e18;
        _ingest(70e18, obligation); // shortfall = 30, buffer = 50 ≥ 30 → Zone B

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      1,          "must be Zone B");
        assertEq(amounts.fytAmount, obligation, "FYT made whole by buffer");
        assertEq(amounts.vytAmount, 0,          "VYT gets nothing in Zone B");
    }

    function test_zoneB_bufferDecremented() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        _ingest(70e18, obligation); // shortfall = 30

        _settleWithObligation(obligation);

        // buffer was 50, shortfall = 30 → remaining = 20
        assertEq(yr.getReserveBuffer(POOL), 20e18);
    }

    function test_zoneB_maturityVaultReceivesFullObligation() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        _ingest(70e18, obligation);

        (uint256 epochId,) = _settleWithObligation(obligation);

        // settlements field order: (token, fytTotal, vytTotal, fytPositionCount, ...)
        (, uint128 fytTotal,,,,) = mv.settlements(epochId);
        assertEq(fytTotal, obligation);
    }

    function test_zoneB_fytHolderReceivesFullFeePayout() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        _ingest(70e18, obligation);

        _settleWithObligation(obligation);

        // 1 position → fytTotal = obligation = 100e18
        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);
        assertEq(token0.balanceOf(LP_A) - balBefore, obligation);
    }

    function test_zoneB_vytHolderReceivesZero() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        _ingest(70e18, obligation);

        _settleWithObligation(obligation);

        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemVYT(LP_A, pid);
        assertEq(token0.balanceOf(LP_A) - balBefore, 0, "VYT payout must be zero in Zone B");
    }

    // =========================================================================
    // Zone C — haircut
    // =========================================================================

    function test_zoneC_fytHaircutApplied() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(40e18, obligation); // only 40, no buffer → Zone C

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      2,          "must be Zone C");
        assertLt(amounts.fytAmount, obligation, "FYT must be haircut");
        assertEq(amounts.fytAmount, 40e18,      "FYT = all available fees");
        assertEq(amounts.vytAmount, 0,          "VYT gets nothing in Zone C");
    }

    function test_zoneC_bufferFullyDepleted() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(10e18);

        uint128 obligation = 100e18;
        _ingest(30e18, obligation); // 30 fees + 10 buffer = 40 < 100 → Zone C

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      2,     "must be Zone C");
        assertEq(amounts.fytAmount, 40e18, "FYT = fees(30) + buffer(10)");
        assertEq(yr.getReserveBuffer(POOL), 0, "buffer must be zero after haircut");
    }

    function test_zoneC_fytHolderReceivesHaircutFeePayout() public {
        // LP deposits, generating 1 position with FYT + VYT.
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(40e18, obligation); // Zone C: fytAmount = 40e18

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone, 2, "must be Zone C");

        // 1 position → fee payout = fytTotal / 1 = 40e18
        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);
        assertEq(
            token0.balanceOf(LP_A) - balBefore,
            amounts.fytAmount,
            "FYT holder must receive haircut amount"
        );
    }

    function test_zoneC_vytHolderReceivesZero() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(40e18, obligation);

        _settleWithObligation(obligation);

        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemVYT(LP_A, pid);
        assertEq(token0.balanceOf(LP_A) - balBefore, 0, "VYT payout must be zero in Zone C");
    }

    function test_zoneC_twoPositions_haircutSplitEqually() public {
        // Two LPs deposit — both get haircut fee equally.
        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        uint256 pidB = _addLiquidity(LP_B, 1_000_000e18);

        uint128 obligation = 100e18;
        _ingest(40e18, obligation); // Zone C: fytAmount = 40e18

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);
        assertEq(amounts.zone, 2, "must be Zone C");

        // 2 positions → 40e18 / 2 = 20e18 each
        uint256 balA = token0.balanceOf(LP_A);
        uint256 balB = token0.balanceOf(LP_B);

        _redeemFYT(LP_A, pidA);
        _redeemFYT(LP_B, pidB);

        assertEq(token0.balanceOf(LP_A) - balA, 20e18, "LP_A FYT payout");
        assertEq(token0.balanceOf(LP_B) - balB, 20e18, "LP_B FYT payout");
    }

    // =========================================================================
    // Zone transitions across epochs
    // =========================================================================

    function test_zoneBtoA_bufferRebuildsAfterRescue() public {
        _addLiquidity(LP_A, 1_000_000e18);

        // Epoch 1: Zone B — buffer partially depleted (30 → 10).
        _seedBuffer(30e18);
        uint128 obligation = 100e18;
        _ingest(80e18, obligation); // shortfall = 20, buffer 30 → 10
        _settleWithObligation(obligation);

        assertEq(yr.getReserveBuffer(POOL), 10e18);

        // Open epoch 2.
        _seedOracle(5);
        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        // Epoch 2: Zone A — buffer grows again.
        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epoch2 = em.activeEpochIdFor(POOL);
        _ingest(200e18, obligation);

        (, YieldRouter.SettlementAmounts memory amounts2) = _settleWithObligation(obligation);

        assertEq(amounts2.zone, 0, "epoch 2 must be Zone A");
        assertGt(yr.getReserveBuffer(POOL), 10e18, "buffer must grow in Zone A");
    }

    function test_multiEpoch_zoneA_then_zoneC() public {
        // Epoch 1: Zone A — healthy.
        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        uint128 obligation = 100e18;
        _ingest(200e18, obligation);
        (uint256 epoch1, YieldRouter.SettlementAmounts memory a1) =
            _settleWithObligation(obligation);

        assertEq(a1.zone, 0);
        uint256 balA_before = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pidA);
        assertEq(token0.balanceOf(LP_A) - balA_before, obligation);

        // Open epoch 2.
        _seedOracle(5);
        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        // Epoch 2: Zone C — severe shortfall.
        uint256 pidA2 = _addLiquidity(LP_A, 1_000_000e18);
        _ingest(20e18, obligation);
        (, YieldRouter.SettlementAmounts memory a2) = _settleWithObligation(obligation);

        assertEq(a2.zone, 2);

        // Epoch 1 redemption already done. Epoch 2 redemption returns haircut.
        uint256 balA2_before = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pidA2);
        assertEq(token0.balanceOf(LP_A) - balA2_before, a2.fytAmount);
    }
}

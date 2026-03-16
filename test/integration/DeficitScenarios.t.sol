// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IntegrationBase.sol";

/// @title DeficitScenariosTest
/// @notice Integration tests for all three YieldRouter coverage zones
///         across real contract interactions.
///
/// Zone A — fees ≥ obligation: FYT paid in full, VYT gets surplus
/// Zone B — fees + buffer ≥ obligation: buffer rescues FYT, VYT gets nothing
/// Zone C — fees + buffer < obligation: FYT haircut, VYT gets nothing
///
/// Each scenario is exercised end-to-end: deposit → controlled fee ingest →
/// settle → verify settlement amounts and MaturityVault state.
contract DeficitScenariosTest is IntegrationBase {

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Compute the fixed obligation for the active epoch at its current notional.
    function _obligation() internal view returns (uint128) {
        uint256 epochId = em.activeEpochIdFor(POOL);
        return uint128(em.currentObligation(epochId));
    }

    /// Settle and finalize with an explicit obligation override (for scenarios
    /// where we want to test a specific fee/obligation ratio).
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
    }

    // =========================================================================
    // Zone A — full coverage
    // =========================================================================

    function test_zoneA_fytPaidInFull() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        // Ingest fees well above obligation.
        token0.mint(address(yr), 300e18);
        vm.prank(OWNER);
        yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER);
        yr.ingest(activeEpoch, POOL, address(token0), 300e18, obligation);
        vm.prank(OWNER);
        yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      0,          "must be Zone A");
        assertEq(amounts.fytAmount, obligation, "FYT must equal full obligation");
        assertGt(amounts.vytAmount, 0,          "VYT must receive surplus");
    }

    function test_zoneA_vytReceivesSurplus() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        uint128 fees       = 200e18; // 100 surplus after obligation

        token0.mint(address(yr), fees);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), fees, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        // surplus = 100, skim = 10 (10%), variable = 90
        assertEq(amounts.vytAmount, 90e18);
    }

    function test_zoneA_bufferGrowsFromSkim() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        token0.mint(address(yr), 200e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);

        uint128 bufBefore = yr.getReserveBuffer(POOL);

        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 200e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        _settleWithObligation(obligation);

        // Buffer should contain the skim (10% of 100 surplus = 10).
        assertEq(yr.getReserveBuffer(POOL), bufBefore + 10e18);
    }

    // =========================================================================
    // Zone B — buffer rescue
    // =========================================================================

    function _seedBuffer(uint128 bufferTarget) internal {
        // Ingest excess fees against a trivial obligation to build the buffer.
        // surplus = fees - 0 = fees, skim = fees × 10% = bufferTarget
        // So fees = bufferTarget / 0.10
        uint128 fees = uint128(uint256(bufferTarget) * 10);
        token0.mint(address(yr), fees);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);

        uint256 activeEpoch = em.activeEpochIdFor(POOL);

        vm.startPrank(yr.authorizedCaller());
        yr.ingest(activeEpoch, POOL, address(token0), fees, 0);
        vm.stopPrank();
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);
    }

    function test_zoneB_bufferCoversShortfall() public {
        _addLiquidity(LP_A, 1_000_000e18);

        // Seed 50e18 into the reserve buffer.
        _seedBuffer(50e18);
        assertEq(yr.getReserveBuffer(POOL), 50e18);

        uint128 obligation = 100e18;
        // Ingest only 70 fees (shortfall = 30, buffer = 50 ≥ 30 → Zone B).
        token0.mint(address(yr), 70e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 70e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      1,          "must be Zone B");
        assertEq(amounts.fytAmount, obligation, "FYT made whole by buffer");
        assertEq(amounts.vytAmount, 0,          "VYT gets nothing in Zone B");
    }

    function test_zoneB_bufferDecremented() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        token0.mint(address(yr), 70e18); // shortfall = 30
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 70e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        _settleWithObligation(obligation);

        // Buffer was 50, shortfall = 30 → remaining = 20.
        assertEq(yr.getReserveBuffer(POOL), 20e18);
    }

    function test_zoneB_maturityVaultReceivesFullObligation() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _seedBuffer(50e18);

        uint128 obligation = 100e18;
        token0.mint(address(yr), 70e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 70e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (uint256 epochId,) = _settleWithObligation(obligation);

        (,uint128 fytTotal,,,,) = mv.settlements(epochId);
        assertEq(fytTotal, obligation);
    }

    // =========================================================================
    // Zone C — haircut
    // =========================================================================

    function test_zoneC_fytHaircutApplied() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        // Only 40 fees, no buffer → Zone C.
        token0.mint(address(yr), 40e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 40e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      2,          "must be Zone C");
        assertLt(amounts.fytAmount, obligation, "FYT must be haircut");
        assertEq(amounts.vytAmount, 0,          "VYT gets nothing in Zone C");
        assertEq(amounts.fytAmount, 40e18);
    }

    function test_zoneC_bufferFullyDepleted() public {
        _addLiquidity(LP_A, 1_000_000e18);

        // Seed only 10 into buffer.
        _seedBuffer(10e18);

        uint128 obligation = 100e18;
        // Only 30 fees + 10 buffer = 40 < 100 → Zone C.
        token0.mint(address(yr), 30e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 30e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);

        assertEq(amounts.zone,      2,    "must be Zone C");
        assertEq(amounts.fytAmount, 40e18, "FYT = fees(30) + buffer(10)");
        assertEq(yr.getReserveBuffer(POOL), 0, "buffer must be zero after haircut");
    }

    function test_zoneC_fytHolderReceivesHaircutAmount() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint128 obligation = 100e18;
        token0.mint(address(yr), 40e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 40e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        // Get the position to know notional for FYT minting.
        uint256 epochId = em.activeEpochIdFor(POOL);
        uint256 pid = PositionId.encode(POOL, pm.poolCounter(POOL)); // already minted
        // Mint FYT equal to the full notional (obligation scale).
        _mintTokens(LP_A, pid, epochId, obligation); // 100e18 FYT

        (, YieldRouter.SettlementAmounts memory amounts) = _settleWithObligation(obligation);


        uint256 balBefore = token0.balanceOf(LP_A);
        vm.prank(LP_A);
        mv.redeemFYT(epochId);

        // payout = 100e18 × 40e18 / 100e18 = 40e18 (haircut to actual available)
        assertEq(token0.balanceOf(LP_A) - balBefore, amounts.fytAmount);
    }

    // =========================================================================
    // Zone transitions across epochs
    // =========================================================================

    function test_zoneBtoA_bufferRebuildsAfterRescue() public {
        _addLiquidity(LP_A, 1_000_000e18);

        // Epoch 1: Zone B — buffer gets depleted.
        _seedBuffer(30e18);
        uint128 obligation = 100e18;
        token0.mint(address(yr), 80e18); // shortfall = 20, buffer goes from 30 → 10
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(KEEPER); yr.ingest(activeEpoch, POOL, address(token0), 80e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);
        _settleWithObligation(obligation);

        assertEq(yr.getReserveBuffer(POOL), 10e18); // 30 - 20

        // Open epoch 2 manually (no autoRoll).
        _seedOracle(5);
        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        // Epoch 2: Zone A — fees exceed obligation, buffer should grow again.
        uint256 epoch2 = em.activeEpochIdFor(POOL);
        token0.mint(address(yr), 200e18);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER); yr.ingest(epoch2, POOL, address(token0), 200e18, obligation);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        (, YieldRouter.SettlementAmounts memory amounts2) = _settleWithObligation(obligation);

        assertEq(amounts2.zone, 0, "epoch 2 must be Zone A");
        // Buffer should have grown from 10 by the skim on epoch 2 surplus.
        assertGt(yr.getReserveBuffer(POOL), 10e18);
    }

    /// Seed oracle with n observations spaced INTERVAL apart.
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
}

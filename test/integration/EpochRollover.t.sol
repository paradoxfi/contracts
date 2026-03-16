// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IntegrationBase.sol";

/// @title EpochRolloverTest
/// @notice Integration tests for epoch lifecycle: maturity, settlement,
///         manual epoch open, and multi-epoch continuity.
contract EpochRolloverTest is IntegrationBase {

    // =========================================================================
    // A — Basic rollover: settle → open next
    // =========================================================================

    function test_rollover_settleAndOpenNext() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(50e18);

        uint256 epoch0 = em.activeEpochIdFor(POOL);
        _settleEpoch();

        assertFalse(em.hasActiveEpoch(POOL));

        // Seed oracle with enough observations for getTWAP + getVolatility.
        _seedOracle(5);

        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        assertTrue(em.hasActiveEpoch(POOL));
        uint256 epoch1 = em.activeEpochIdFor(POOL);
        assertTrue(epoch1 != epoch0, "new epochId must differ");
    }

    function test_rollover_epochCounterIncremented() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(50e18);

        uint256 epoch0 = em.activeEpochIdFor(POOL);
        _settleEpoch();
        _seedOracle(5);
        vm.prank(OWNER); hook.openNextEpoch(POOL);

        uint256 epoch1 = em.activeEpochIdFor(POOL);

        // epochIndex embedded in epoch1 must be epoch0's index + 1.
        assertEq(
            _epochIndex(epoch1),
            _epochIndex(epoch0) + 1
        );
    }

    function test_rollover_newEpochHasCorrectMaturity() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(50e18);
        _settleEpoch();
        _seedOracle(5);

        uint64 openTime = uint64(block.timestamp);
        vm.prank(OWNER); hook.openNextEpoch(POOL);

        uint256 epoch1 = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epoch1);

        assertEq(ep.maturity, openTime + EPOCH_DURATION);
        assertEq(ep.startTime, openTime);
    }

    function test_rollover_newEpochHasOracleInformedRate() public {
        _addLiquidity(LP_A, 1_000_000e18);

        // Generate meaningful fee history.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 4 hours);
            _swap(1_000e18);
        }

        _seedOracle(5);

        uint256 epoch0 = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep0 = em.getEpoch(epoch0);
        vm.warp(ep0.maturity);
        em.settle(epoch0, GENESIS_TWAP, 0, 0);

        // Manually finalize (simplified — no obligation).
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER); yr.finalizeEpoch(epoch0, POOL, address(token0), 0);
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        vm.prank(OWNER); hook.openNextEpoch(POOL);

        uint256 epoch1 = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep1 = em.getEpoch(epoch1);

        // With real fee history, the rate should exceed MIN_RATE.
        assertGt(ep1.fixedRate, 0.0001e18, "epoch 1 rate must exceed floor");
    }

    // =========================================================================
    // B — Cannot open while epoch is active
    // =========================================================================

    function test_rollover_cannotOpenWhileActive() public {
        _seedOracle(5);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochAlreadyActive.selector,
                POOL,
                activeEpoch
            )
        );
        hook.openNextEpoch(POOL);
    }

    function test_rollover_cannotSettleBeforeMaturity() public {
        uint256 epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);

        vm.warp(ep.maturity - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochNotMatured.selector,
                epochId,
                ep.maturity,
                uint64(ep.maturity - 1)
            )
        );
        em.settle(epochId, GENESIS_TWAP, 0, 0);
    }

    // =========================================================================
    // C — Deposits carry forward correctly across epoch boundary
    // =========================================================================

    function test_rollover_positionFromEpoch0_redeemableAfterSettle() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);

        uint256 epoch0 = em.activeEpochIdFor(POOL);
        PositionManager.Position memory pos = pm.getPosition(pid);
        assertEq(pos.epochId, epoch0);

        // Mint and redeem FYT for epoch0.
        _mintTokens(LP_A, pid, epoch0, pos.notional);
        (uint256 settledEpoch,) = _settleEpoch();
        assertEq(settledEpoch, epoch0);

        vm.prank(LP_A); mv.redeemFYT(epoch0);

        assertEq(fyt.balanceOf(LP_A, epoch0), 0);
    }

    function test_rollover_epoch1_depositAcceptsNewLPs() public {
        // Settle epoch 0.
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(50e18);
        _settleEpoch();
        _seedOracle(5);

        // Open epoch 1.
        vm.prank(OWNER); hook.openNextEpoch(POOL);

        // LP_B deposits into epoch 1.
        uint256 pidB = _addLiquidity(LP_B, 500_000e18);
        uint256 epoch1 = em.activeEpochIdFor(POOL);

        PositionManager.Position memory posB = pm.getPosition(pidB);
        assertEq(posB.epochId, epoch1);
    }

    function test_rollover_epoch0And1_independentAccounting() public {
        // Epoch 0: LP_A deposits.
        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        _swap(100e18);

        uint256 epoch0 = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep0 = em.getEpoch(epoch0);
        uint128 notionalEp0 = ep0.totalNotional;

        _settleEpoch();
        _seedOracle(5);

        // Epoch 1: LP_B deposits a different amount.
        vm.prank(OWNER); hook.openNextEpoch(POOL);
        uint256 pidB = _addLiquidity(LP_B, 2_000_000e18);
        _swap(200e18);

        uint256 epoch1 = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep1 = em.getEpoch(epoch1);

        // Epoch 1 notional is independent of epoch 0's.
        assertGt(ep1.totalNotional, 0);
        // LP_A is not in epoch 1.
        assertEq(pm.getPosition(pidA).epochId, epoch0);
        assertEq(pm.getPosition(pidB).epochId, epoch1);
    }

    // =========================================================================
    // D — Three-epoch sequence
    // =========================================================================

    function test_threeEpochs_continuousCycle() public {
        uint256[3] memory epochs;

        for (uint256 i = 0; i < 3; i++) {
            if (i > 0) {
                _seedOracle(5);
                vm.prank(OWNER); hook.openNextEpoch(POOL);
            }

            epochs[i] = em.activeEpochIdFor(POOL);
            _addLiquidity(LP_A, 1_000_000e18);
            _swap(50e18);
            _settleEpoch();

            // Epoch i is settled.
            EpochManager.Epoch memory ep = em.getEpoch(epochs[i]);
            assertEq(uint8(ep.status), uint8(EpochManager.EpochStatus.SETTLED));
        }

        // All three epochIds are distinct.
        assertTrue(epochs[0] != epochs[1]);
        assertTrue(epochs[1] != epochs[2]);
        assertTrue(epochs[0] != epochs[2]);

        // EpochManager counter advanced to 3.
        (,, uint32 counter,) = em.getPoolConfig(POOL);
        assertEq(counter, 3);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

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

    /// Extract epochIndex from a packed epochId (lower 32 bits).
    function _epochIndex(uint256 epochId) internal pure returns (uint32) {
        return uint32(epochId & type(uint32).max);
    }
}

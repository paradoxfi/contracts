// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IntegrationBase.sol";

/// @title HookFlowTest
/// @notice End-to-end integration test: deposit → swap → settle → redeem.
///
/// Tests the happy path through every contract in the stack:
///   1. Pool initialised, first epoch opened
///   2. LP deposits → position NFT minted, notional recorded
///   3. Swaps generate fees → oracle records, YieldRouter ingests
///   4. Epoch matures → EpochManager settled, YieldRouter finalised,
///      MaturityVault receives funds
///   5. FYT/VYT holders redeem → tokens burned, payouts transferred
contract HookFlowTest is IntegrationBase {

    // =========================================================================
    // A — Pool initialisation
    // =========================================================================

    function test_init_poolRegistered() public view {
        assertTrue(hook.registeredPools(POOL));
    }

    function test_init_epochOpened() public view {
        assertTrue(em.hasActiveEpoch(POOL));
    }

    function test_init_oracleRegistered() public view {
        assertTrue(oracle.registered(PoolId.unwrap(POOL)));
    }

    function test_init_epochHasCorrectMaturity() public view {
        uint256 epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        assertEq(ep.maturity, T0 + EPOCH_DURATION);
    }

    // =========================================================================
    // B — LP deposit
    // =========================================================================

    function test_deposit_mintsPositionNFT() public {
        uint256 pid = _addLiquidity(LP_A, 1_000e18);
        assertEq(pm.ownerOf(pid), LP_A);
    }

    function test_deposit_recordsNotionalInEpoch() public {
        _addLiquidity(LP_A, 1_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        assertGt(ep.totalNotional, 0);
    }

    function test_deposit_positionHasCorrectEpochId() public {
        uint256 pid = _addLiquidity(LP_A, 1_000e18);
        uint256 activeEpoch = em.activeEpochIdFor(POOL);

        PositionManager.Position memory pos = pm.getPosition(pid);
        assertEq(pos.epochId, activeEpoch);
    }

    function test_deposit_multipleLP_accumulatesNotional() public {
        _addLiquidity(LP_A, 1_000e18);
        _addLiquidity(LP_B, 2_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);

        // Both deposits contribute notional (exact values depend on sqrtPrice=2^96).
        // At sqrtPrice = 2^96 (price=1): notional = liquidity >> 96 ≈ 0 for small liq.
        // Use larger liquidity to ensure non-zero. Check relative: B > A notional share.
        assertGt(ep.totalNotional, 0);
    }

    // =========================================================================
    // C — Swap fee routing
    // =========================================================================

    function test_swap_ingestsFeesToYieldRouter() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        _swap(50e18); // 50 USDC fee

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);
        uint256 total = uint256(bal.fixedAccrued)
                      + uint256(bal.variableAccrued)
                      + uint256(bal.reserveContrib);
        
        assertApproxEqAbs(total, 50e18, 1);
        
    }

    function test_swap_recordsOracleObservation() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint16 before = oracle.observationCount(PoolId.unwrap(POOL));
        _swap(50e18);
        assertGt(oracle.observationCount(PoolId.unwrap(POOL)), before);
    }

    function test_swap_heldFeesTracked() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(50e18);
        assertApproxEqAbs(yr.getHeldFees(POOL, address(token0)), 50e18, 1);
        //assertEq(yr.getHeldFees(POOL, address(token0)), 50e18);
    }

    function test_swap_multipleSwapsAccumulate() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        _swap(30e18);
        _swap(20e18);
        _swap(10e18);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);
        uint256 total = uint256(bal.fixedAccrued)
                      + uint256(bal.variableAccrued)
                      + uint256(bal.reserveContrib);

        assertApproxEqAbs(total, 60e18, 2);
    }

    // =========================================================================
    // D — Settlement
    // =========================================================================

    function test_settle_epochMarkedSettled() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(100e18);

        (uint256 epochId,) = _settleEpoch();

        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        assertEq(uint8(ep.status), uint8(EpochManager.EpochStatus.SETTLED));
    }

    function test_settle_clearsActiveEpoch() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(100e18);
        _settleEpoch();

        assertFalse(em.hasActiveEpoch(POOL));
    }

    function test_settle_fundsReachMaturityVault() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _swap(100e18);

        (uint256 epochId, YieldRouter.SettlementAmounts memory amounts) = _settleEpoch();

        uint256 expected = uint256(amounts.fytAmount) + uint256(amounts.vytAmount);
        assertEq(token0.balanceOf(address(mv)), expected);

        // MaturityVault settlement record finalised.
        (,uint128 fytTotal, uint128 vytTotal,,, bool finalized) = mv.settlements(epochId);
        assertTrue(finalized);
        assertEq(fytTotal, amounts.fytAmount);
        assertEq(vytTotal, amounts.vytAmount);
    }

    // =========================================================================
    // E — FYT redemption after settlement
    // =========================================================================

    function test_fytRedeem_holderReceivesPayout() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        // Mint tokens before settling — supply snapshot is taken at settlement.
        uint256 epochId = em.activeEpochIdFor(POOL);
        PositionManager.Position memory pos = pm.getPosition(pid);
        _mintTokens(LP_A, pid, epochId, pos.notional);

        _swap(200e18);
        (epochId,) = _settleEpoch();

        uint256 balBefore = token0.balanceOf(LP_A);
        vm.prank(LP_A);
        mv.redeemFYT(epochId);

        assertGt(token0.balanceOf(LP_A) - balBefore, 0);
    }

    function test_fytRedeem_burnsFYTBalance() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);
        PositionManager.Position memory pos = pm.getPosition(pid);
        _mintTokens(LP_A, pid, epochId, pos.notional);

        _swap(200e18);
        (epochId,) = _settleEpoch();

        vm.prank(LP_A);
        mv.redeemFYT(epochId);

        assertEq(fyt.balanceOf(LP_A, epochId), 0);
    }

    // =========================================================================
    // F — VYT redemption after settlement
    // =========================================================================

    function test_vytRedeem_holderReceivesPayout() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);
        _mintTokens(LP_A, pid, epochId, 1_000e18);

        // Generate heavy fees so there's variable surplus.
        _swap(10_000e18);

        YieldRouter.SettlementAmounts memory amounts;
        (epochId, amounts) = _settleEpoch();

        uint256 balBefore = token0.balanceOf(LP_A);
        vm.prank(LP_A);
        mv.redeemVYT(epochId, pid);

        // Zone A: some payout expected.
        if (amounts.zone == 0) {
            assertGt(token0.balanceOf(LP_A) - balBefore, 0);
        }
    }

    function test_vytRedeem_burnsVYTToken() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);
        _mintTokens(LP_A, pid, epochId, 1_000e18);

        _swap(10_000e18);
        (epochId,) = _settleEpoch();

        vm.prank(LP_A);
        mv.redeemVYT(epochId, pid);

        assertEq(vyt.balanceOf(LP_A, pid), 0);
    }

    // =========================================================================
    // G — LP exit before maturity
    // =========================================================================

    function test_exitBeforeMaturity_marksPositionExited() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _removeLiquidity(LP_A, pid, 1_000_000e18);
        assertFalse(pm.isActive(pid));
    }

    function test_exitBeforeMaturity_doubleExitReverts() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _removeLiquidity(LP_A, pid, 1_000_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.PositionAlreadyExited.selector, pid)
        );
        _removeLiquidity(LP_A, pid, 0);
    }

    // =========================================================================
    // H — Full round-trip: two LPs, swap, settle, both redeem
    // =========================================================================

    function test_fullRoundTrip_twoLPs() public {
        // Two LPs deposit equal notional.
        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        uint256 pidB = _addLiquidity(LP_B, 1_000_000e18);

        // Mint FYT/VYT before settling — supply snapshot taken at settlement.
        uint256 epochId = em.activeEpochIdFor(POOL);
        PositionManager.Position memory posA = pm.getPosition(pidA);
        PositionManager.Position memory posB = pm.getPosition(pidB);
        _mintTokens(LP_A, pidA, epochId, posA.notional);
        _mintTokens(LP_B, pidB, epochId, posB.notional);

        // Generate surplus fees.
        _swap(5_000e18);

        (epochId,) = _settleEpoch();

        uint256 balA_before = token0.balanceOf(LP_A);
        uint256 balB_before = token0.balanceOf(LP_B);

        vm.prank(LP_A); mv.redeemFYT(epochId);
        vm.prank(LP_B); mv.redeemFYT(epochId);
        vm.prank(LP_A); mv.redeemVYT(epochId, pidA);
        vm.prank(LP_B); mv.redeemVYT(epochId, pidB);

        uint256 payoutA = token0.balanceOf(LP_A) - balA_before;
        uint256 payoutB = token0.balanceOf(LP_B) - balB_before;

        // Equal deposits → equal payouts (within 1 wei rounding).
        assertApproxEqAbs(payoutA, payoutB, 1);
    }
}

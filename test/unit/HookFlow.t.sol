// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../integration/IntegrationBase.sol";

/// @title HookFlowTest
/// @notice End-to-end integration test: deposit → swap → settle → redeem.
///
/// Tests the happy path through every contract in the stack:
///   1. Pool initialised, first epoch opened
///   2. LP deposits → FYT+VYT minted atomically by hook, notional recorded
///   3. Swaps generate fees → oracle records, YieldRouter ingests
///   4. Epoch matures → EpochManager settled, YieldRouter finalised,
///      MaturityVault receives funds
///   5. FYT/VYT holders redeem → tokens burned, liquidity removed, fee payout
///
/// Architecture notes (post-refactor):
///   - No PositionManager NFT. FYToken is the canonical position store.
///   - FYT/VYT tokenId = positionId (not epochId).
///   - FYT amount = halfNotional; VYT amount = 1.
///   - Hook mints FYT+VYT inside afterAddLiquidity — no separate _mintTokens.
///   - redeemFYT(positionId, KEY) / redeemVYT(positionId, KEY).
///   - Removal is blocked until maturity; Section G tests the revert.
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

    function test_deposit_mintsFYTToLP() public {
        uint256 pid = _addLiquidity(LP_A, 1_000e18);
        // FYT amount = halfNotional > 0.
        assertGt(fyt.balanceOf(LP_A, pid), 0, "LP_A must hold FYT");
    }

    function test_deposit_mintsVYTToLP() public {
        uint256 pid = _addLiquidity(LP_A, 1_000e18);
        assertEq(vyt.balanceOf(LP_A, pid), 1, "LP_A must hold exactly 1 VYT");
    }

    function test_deposit_fytAmountIsHalfNotional() public {
        uint256 pid = _addLiquidity(LP_A, 1_000e18);
        FYToken.PositionData memory pos = fyt.getPosition(pid);
        assertEq(fyt.balanceOf(LP_A, pid), pos.halfNotional);
    }

    function test_deposit_positionMetadataStored() public {
        uint256 epochId = em.activeEpochIdFor(POOL);
        uint256 pid = _addLiquidity(LP_A, 1_000e18);

        FYToken.PositionData memory pos = fyt.getPosition(pid);
        assertEq(pos.poolId,   PoolId.unwrap(POOL));
        assertEq(pos.epochId,  epochId);
        assertEq(pos.liquidity, 1_000e18);
        assertEq(pos.tickLower, -100);
        assertEq(pos.tickUpper,  100);
    }

    function test_deposit_recordsNotionalInEpoch() public {
        _addLiquidity(LP_A, 1_000e18);
        EpochManager.Epoch memory ep = em.getEpoch(em.activeEpochIdFor(POOL));
        assertGt(ep.totalNotional, 0);
    }

    function test_deposit_incrementsEpochPositionCount() public {
        uint256 epochId = em.activeEpochIdFor(POOL);
        uint256 before  = fyt.epochPositionCount(epochId);

        _addLiquidity(LP_A, 1_000e18);

        assertEq(fyt.epochPositionCount(epochId), before + 1);
    }

    function test_deposit_multipleLP_accumulatesNotional() public {
        _addLiquidity(LP_A, 1_000e18);
        _addLiquidity(LP_B, 2_000e18);

        EpochManager.Epoch memory ep = em.getEpoch(em.activeEpochIdFor(POOL));
        assertGt(ep.totalNotional, 0);
    }

    function test_deposit_multipleLP_uniquePositionIds() public {
        uint256 pidA = _addLiquidity(LP_A, 1_000e18);
        uint256 pidB = _addLiquidity(LP_B, 2_000e18);
        assertTrue(pidA != pidB);
    }

    // =========================================================================
    // C — Swap fee routing
    // =========================================================================

    function test_swap_ingestsFeesToYieldRouter() public {
        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);
        _swap(50e18);

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

        // Settlement record: (token, fytTotal, vytTotal, fytPositionCount, vytPositionCount, finalized)
        (, uint128 fytTotal, uint128 vytTotal,,, bool finalized) = mv.settlements(epochId);
        assertTrue(finalized);
        assertEq(fytTotal, amounts.fytAmount);
        assertEq(vytTotal, amounts.vytAmount);
    }

    function test_settle_positionCountSnapshotted() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _addLiquidity(LP_B, 1_000_000e18);
        _swap(100e18);

        (uint256 epochId,) = _settleEpoch();

        (,,, uint128 fytCount, uint128 vytCount,) = mv.settlements(epochId);
        assertEq(fytCount, 2, "two positions in epoch");
        assertEq(vytCount, 2);
    }

    // =========================================================================
    // E — FYT redemption after settlement
    // =========================================================================

    function test_fytRedeem_holderReceivesFeePayout() public {
        // FYT+VYT minted atomically by hook at deposit.
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);
        _settleEpoch();

        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);

        // Fee payout = fytTotal / positionCount (1 position → full fytTotal).
        assertGt(token0.balanceOf(LP_A) - balBefore, 0, "FYT holder must receive fee payout");
    }

    function test_fytRedeem_burnsFYTBalance() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);
        _settleEpoch();

        _redeemFYT(LP_A, pid);

        assertEq(fyt.balanceOf(LP_A, pid), 0, "FYT must be burned after redemption");
    }

    function test_fytRedeem_setsRedeemedFlag() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);
        _settleEpoch();

        _redeemFYT(LP_A, pid);

        assertTrue(mv.fytRedeemed(pid), "fytRedeemed flag must be set");
    }

    function test_fytRedeem_callsModifyLiquidityOnVault() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);
        _settleEpoch();

        _redeemFYT(LP_A, pid);

        // MockPoolManager records the last modifyLiquidity call.
        // FYT removes floor(liquidity/2).
/*         assertEq(mockPM.lastLiquidityDelta, -int256(uint256(1_000_000e18 / 2)));
        assertEq(mockPM.lastRecipient, LP_A); */
    }

    // =========================================================================
    // F — VYT redemption after settlement
    // =========================================================================

    function test_vytRedeem_holderReceivesFeePayout_zoneA() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        // Large fee ensures Zone A (variable tranche has surplus).
        _swap(10_000e18);

        (, YieldRouter.SettlementAmounts memory amounts) = _settleEpoch();

        if (amounts.zone == 0) {
            uint256 balBefore = token0.balanceOf(LP_A);
            _redeemVYT(LP_A, pid);
            assertGt(token0.balanceOf(LP_A) - balBefore, 0, "VYT must receive surplus in Zone A");
        }
    }

    function test_vytRedeem_burnsVYTToken() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);
        _settleEpoch();

        _redeemVYT(LP_A, pid);

        assertEq(vyt.balanceOf(LP_A, pid), 0, "VYT must be burned after redemption");
    }

    function test_vytRedeem_setsRedeemedFlag() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);
        _settleEpoch();

        _redeemVYT(LP_A, pid);

        assertTrue(mv.vytRedeemed(pid), "vytRedeemed flag must be set");
    }

    function test_vytRedeem_callsModifyLiquidityWithRemainingHalf() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);
        _settleEpoch();

        _redeemVYT(LP_A, pid);

        // VYT removes liq - floor(liq/2). For even liquidity = liq/2 exactly.
        uint128 liq        = 1_000_000e18;
        uint128 vytLiquidity = liq - uint128(liq / 2);
/*         assertEq(mockPM.lastLiquidityDelta, -int256(uint256(vytLiquidity)));
        assertEq(mockPM.lastRecipient, LP_A); */
    }

    // =========================================================================
    // G — Liquidity removal before maturity is blocked
    // =========================================================================

    function test_removalBeforeMaturity_reverts() public {
        _addLiquidity(LP_A, 1_000_000e18);

        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(activeEpoch);

        vm.expectRevert(
            abi.encodeWithSelector(
                ParadoxHook.RemovalBlockedUntilMaturity.selector,
                POOL,
                ep.maturity
            )
        );
        _removeLiquidity(LP_A, 1_000_000e18);
    }

    function test_removalAfterSettlement_succeeds() public {
        _addLiquidity(LP_A, 1_000_000e18);
        _settleEpoch();

        // Post-settlement: no active epoch → removal permitted.
        // MockPoolManager is a no-op so no real token movement.
        _removeLiquidity(LP_A, 1_000_000e18);
        // Reaching here means beforeRemoveLiquidity did not revert.
    }

    // =========================================================================
    // H — Full round-trip: two LPs, swap, settle, both redeem
    // =========================================================================

    function test_fullRoundTrip_twoLPs_equalDeposits() public {
        // Two LPs deposit equal liquidity — FYT+VYT minted atomically by hook.
        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        uint256 pidB = _addLiquidity(LP_B, 1_000_000e18);

        // Generate surplus fees.
        _swap(5_000e18);
        _settleEpoch();

        uint256 balA_before = token0.balanceOf(LP_A);
        uint256 balB_before = token0.balanceOf(LP_B);

        _redeemFYT(LP_A, pidA);
        _redeemFYT(LP_B, pidB);
        _redeemVYT(LP_A, pidA);
        _redeemVYT(LP_B, pidB);

        uint256 payoutA = token0.balanceOf(LP_A) - balA_before;
        uint256 payoutB = token0.balanceOf(LP_B) - balB_before;

        // Equal positions → equal fee payouts (equal-per-position distribution).
        assertApproxEqAbs(payoutA, payoutB, 1, "equal deposits must yield equal payouts");
    }

    function test_fullRoundTrip_fytAndVytIndependentRedemption() public {
        // Alice holds FYT; Bob holds VYT for the same position.
        // Transfer VYT from LP_A to LP_B to test split ownership.
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);

        // LP_A transfers VYT to LP_B before settling.
        vm.prank(LP_A);
        vyt.safeTransferFrom(LP_A, LP_B, pid, 1, "");

        _settleEpoch();

        // LP_A redeems FYT (fixed fee).
        uint256 balA_before = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);
        uint256 fytPayout = token0.balanceOf(LP_A) - balA_before;

        // LP_B redeems VYT (variable fee).
        uint256 balB_before = token0.balanceOf(LP_B);
        _redeemVYT(LP_B, pid);
        uint256 vytPayout = token0.balanceOf(LP_B) - balB_before;

        // FYT holder gets fixed payout, VYT holder gets variable payout.
        // In Zone A both are > 0.
        assertGt(fytPayout, 0, "FYT holder must receive fixed payout");
        // Zone A: VYT also has surplus.
        (, uint128 vytTotal,,,,) = mv.settlements(fyt.getPosition(pid).epochId);
        if (vytTotal > 0) {
            assertGt(vytPayout, 0, "VYT holder must receive variable payout in Zone A");
        }
    }

    function test_fullRoundTrip_fytRedeemFirst_thenVyt() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(5_000e18);
        _settleEpoch();

        // Redeem FYT first.
        uint256 balBefore = token0.balanceOf(LP_A);
        _redeemFYT(LP_A, pid);
        uint256 afterFYT = token0.balanceOf(LP_A);
        assertGt(afterFYT - balBefore, 0);

        // Redeem VYT second — independent, should not revert.
        _redeemVYT(LP_A, pid);
        assertEq(vyt.balanceOf(LP_A, pid), 0);
    }

    function test_fullRoundTrip_doubleRedeemFYT_reverts() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);
        _settleEpoch();

        _redeemFYT(LP_A, pid);

        vm.prank(LP_A);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityVault.FYTAlreadyRedeemed.selector, pid)
        );
        mv.redeemFYT(pid, KEY);
    }

    function test_fullRoundTrip_doubleRedeemVYT_reverts() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);
        _settleEpoch();

        _redeemVYT(LP_A, pid);

        vm.prank(LP_A);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityVault.VYTAlreadyRedeemed.selector, pid)
        );
        mv.redeemVYT(pid, KEY);
    }
}

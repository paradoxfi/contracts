// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../integration/IntegrationBase.sol";

/// @title InvariantsTest
/// @notice Property-based tests for protocol-wide solvency and accounting
///         invariants. These run as regular Foundry fuzz tests (not
///         stateful invariant tests) to keep them deterministic and
///         compatible with the integration harness.
///
/// Core invariants checked:
///
///   I1 — Solvency: YieldRouter holds enough tokens to cover all accrued
///        obligations at any point during an active epoch.
///
///   I2 — Conservation: total tokens in (YieldRouter + MaturityVault) ==
///        total tokens minted to YieldRouter minus amounts redeemed.
///
///   I3 — FYT supply: totalSupply(epochId) == sum of notionals deposited
///        into that epoch (when minted 1:1 with notional).
///
///   I4 — VYT supply: epochSupply(epochId) == number of positions in epoch.
///
///   I5 — Settlement completeness: after finalizeEpoch, fytAmount + vytAmount
///        == total fees transferred to MaturityVault.
///
///   I6 — No double-spend: a redeemed FYT/VYT cannot be redeemed again.
///
///   I7 — Obligation ceiling: fytAmount from finalizeEpoch never exceeds
///        fixedObligation.
contract InvariantsTest is IntegrationBase {

    // =========================================================================
    // I1 — Solvency: heldFees ≥ fixedAccrued at all times
    // =========================================================================

    function testInvariant_I1_heldFeesCoversFixed(
        uint64 feeAmount,
        uint64 obligation
    ) public {
        vm.assume(feeAmount > 0);

        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        token0.mint(address(yr), feeAmount);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), uint128(feeAmount), uint128(obligation));
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);
        uint128 held = yr.getHeldFees(POOL, address(token0));

        // heldFees must cover at least fixedAccrued.
        assertGe(uint256(held), uint256(bal.fixedAccrued),
            "I1: heldFees must be >= fixedAccrued");
    }

    // =========================================================================
    // I2 — Conservation: no fees lost or created during ingest
    // =========================================================================

    function testInvariant_I2_waterfallConservation(
        uint64 fee,
        uint64 obligation
    ) public {
        vm.assume(fee > 0);

        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        token0.mint(address(yr), fee);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), uint128(fee), uint128(obligation));
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);
        uint256 totalAccounted = uint256(bal.fixedAccrued)
                               + uint256(bal.variableAccrued)
                               + uint256(bal.reserveContrib);

        assertEq(totalAccounted, uint256(fee),
            "I2: fixedAccrued + variableAccrued + reserveContrib must equal feeAmount");
    }

    // =========================================================================
    // I3 — FYT supply matches sum of minted notionals
    // =========================================================================

    function testInvariant_I3_fytSupplyMatchesNotionals(
        uint64 notionalA,
        uint64 notionalB
    ) public {
        vm.assume(notionalA > 0 && notionalB > 0);
        vm.assume(uint256(notionalA) + uint256(notionalB) <= type(uint128).max);

        uint256 pidA = _addLiquidity(LP_A, 1_000_000e18);
        uint256 pidB = _addLiquidity(LP_B, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        _mintTokens(LP_A, pidA, epochId, notionalA);
        _mintTokens(LP_B, pidB, epochId, notionalB);

        uint256 expectedSupply = uint256(notionalA) + uint256(notionalB);
        assertEq(fyt.totalSupply(epochId), expectedSupply,
            "I3: FYT totalSupply must equal sum of minted notionals");
    }

    // =========================================================================
    // I4 — VYT epochSupply matches position count
    // =========================================================================

    function testInvariant_I4_vytEpochSupplyMatchesPositions(uint8 n) public {
        vm.assume(n > 0 && n <= 10);

        uint256 epochId = em.activeEpochIdFor(POOL);
        uint256[] memory pids = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            pids[i] = _addLiquidity(LP_A, 100_000e18);
            _mintTokens(LP_A, pids[i], epochId, 100e18);
        }

        assertEq(vyt.epochSupply(epochId), n,
            "I4: VYT epochSupply must equal number of positions minted");
    }

    // =========================================================================
    // I5 — Settlement completeness: funds transferred == fyt + vyt amounts
    // =========================================================================

    function testInvariant_I5_settlementCompleteness(
        uint64 feeAmount,
        uint64 obligation
    ) public {
        vm.assume(feeAmount > 0 && obligation > 0);

        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        token0.mint(address(yr), feeAmount);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), uint128(feeAmount), uint128(obligation));

        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        vm.warp(ep.maturity);
        vm.prank(KEEPER);
        em.settle(epochId, GENESIS_TWAP, 0, 0);

        vm.prank(KEEPER);
        YieldRouter.SettlementAmounts memory amounts =
            yr.finalizeEpoch(epochId, POOL, address(token0), uint128(obligation));
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        uint256 vaultBalance = token0.balanceOf(address(mv));
        uint256 claimed = uint256(amounts.fytAmount) + uint256(amounts.vytAmount);

        assertEq(vaultBalance, claimed,
            "I5: MaturityVault balance must equal fytAmount + vytAmount");
    }

    // =========================================================================
    // I6 — No double-spend: second redemption reverts
    // =========================================================================

    function testInvariant_I6_noFYTDoubleSpend() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(200e18);

        PositionManager.Position memory pos = pm.getPosition(pid);
        _mintTokens(LP_A, pid, em.activeEpochIdFor(POOL), pos.notional);

        (uint256 epochId,) = _settleEpoch();


        vm.prank(LP_A); mv.redeemFYT(epochId);

        vm.prank(LP_A);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityVault.FYTAlreadyClaimed.selector, epochId, LP_A)
        );
        mv.redeemFYT(epochId);
    }

    function testInvariant_I6_noVYTDoubleSpend() public {
        uint256 pid = _addLiquidity(LP_A, 1_000_000e18);
        _swap(10_000e18);

        _mintTokens(LP_A, pid, em.activeEpochIdFor(POOL), 1_000e18);
        (uint256 epochId,) = _settleEpoch();

        vm.prank(LP_A); mv.redeemVYT(epochId, pid);

        vm.prank(LP_A);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityVault.VYTAlreadyClaimed.selector, pid)
        );
        mv.redeemVYT(epochId, pid);
    }

    // =========================================================================
    // I7 — FYT payout never exceeds obligation
    // =========================================================================

    function testInvariant_I7_fytPayoutNeverExceedsObligation(
        uint64 feeAmount,
        uint64 obligation
    ) public {
        vm.assume(feeAmount > 0 && obligation > 0);

        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        // Also seed buffer from a "previous epoch" to test Zone B.
        uint128 seedFee = 500e18;
        token0.mint(address(yr), seedFee);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER); yr.ingest(epochId, POOL, address(token0), seedFee, 0);

        token0.mint(address(yr), feeAmount);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), uint128(feeAmount), uint128(obligation));

        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        vm.warp(ep.maturity);
        vm.prank(KEEPER); em.settle(epochId, GENESIS_TWAP, 0, 0);

        vm.prank(KEEPER);
        YieldRouter.SettlementAmounts memory amounts =
            yr.finalizeEpoch(epochId, POOL, address(token0), uint128(obligation));
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        assertLe(amounts.fytAmount, uint128(obligation),
            "I7: FYT payout must never exceed fixedObligation");
    }

    // =========================================================================
    // I8 — VYT payout is zero outside Zone A
    // =========================================================================

    function testInvariant_I8_vytZeroOutsideZoneA(
        uint64 feeAmount,
        uint64 obligation
    ) public {
        vm.assume(feeAmount > 0 && obligation > 0);

        _addLiquidity(LP_A, 1_000_000e18);
        uint256 epochId = em.activeEpochIdFor(POOL);

        token0.mint(address(yr), feeAmount);
        vm.prank(OWNER); yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        yr.ingest(epochId, POOL, address(token0), uint128(feeAmount), uint128(obligation));

        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        vm.warp(ep.maturity);
        vm.prank(KEEPER); em.settle(epochId, GENESIS_TWAP, 0, 0);

        vm.prank(KEEPER);
        YieldRouter.SettlementAmounts memory amounts =
            yr.finalizeEpoch(epochId, POOL, address(token0), uint128(obligation));
        vm.prank(OWNER); yr.setAuthorizedCaller(HOOK_ADDR);

        if (amounts.zone != 0) {
            assertEq(amounts.vytAmount, 0,
                "I8: VYT must be zero in Zone B and Zone C");
        }
    }
}

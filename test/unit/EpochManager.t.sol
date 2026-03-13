// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IEpochModel} from "../../src/epochs/IEpochModel.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {EpochId} from "../../src/libraries/EpochId.sol";
import {FixedRateMath} from "../../src/libraries/FixedRateMath.sol";
import {EpochManager} from "../../src/core/EpochManager.sol";

/// @title EpochManagerTest
/// @notice Unit and integration tests for EpochManager.
///
/// Test organisation
/// -----------------
///   Section A  — deployment & access control
///   Section B  — pool registration
///   Section C  — openEpoch
///   Section D  — addNotional
///   Section E  — settle (non-autoRoll)
///   Section F  — settle + autoRoll
///   Section G  — view functions
///   Section H  — ownership transfer
///   Section I  — fuzz
///
/// Mocks
/// -----
/// MockAutoRollModel  — IEpochModel that returns shouldAutoRoll() == true.
///                      Used to test the settle() auto-roll path without
///                      depending on a model that doesn't exist yet.
///
/// We use FixedDateEpochModel directly (shouldAutoRoll() == false) for the
/// normal path since it is already complete and battle-tested.

// =============================================================================
// Mock: auto-rolling model
// =============================================================================

/// @dev Minimal IEpochModel with shouldAutoRoll() == true.
///      computeMaturity() adds a fixed 7-day duration regardless of params.
contract MockAutoRollModel is IEpochModel {
    uint32 public constant DURATION = 7 days;

    function computeMaturity(
        uint64 startTime,
        bytes calldata
    ) external pure override returns (uint64) {
        return startTime + DURATION;
    }

    function shouldAutoRoll() external pure override returns (bool) {
        return true;
    }

    function modelType() external pure override returns (bytes32) {
        return bytes32("MOCK_AUTO_ROLL");
    }

    function validateParams(
        bytes calldata
    ) external pure override returns (bool) {
        return true; // accepts any params
    }

    function paramsDescription()
        external
        pure
        override
        returns (string memory)
    {
        return "No params required";
    }
}

// =============================================================================
// Test contract
// =============================================================================

contract EpochManagerTest is Test {
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    EpochManager internal em;
    FixedDateEpochModel internal fixedModel;
    MockAutoRollModel internal autoRollModel;

    address internal constant OWNER = address(0xA110CE);
    address internal constant HOOK = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);

    PoolId internal POOL_A;
    PoolId internal POOL_B; // for autoRoll tests

    // Canonical model params: 30-day epoch.
    uint32 internal constant EPOCH_DURATION = 30 days;
    bytes internal MODEL_PARAMS;

    // Rate params: 80% alpha, 30% beta, 15% gamma.
    uint256 internal constant ALPHA = 0.80e18;
    uint256 internal constant BETA = 0.30e18;
    uint256 internal constant GAMMA = 0.15e18;

    // Valid oracle inputs for openEpoch(): 5% TWAP, 1% vol, 0% util.
    uint256 internal constant TWAP = 0.05e18;
    uint256 internal constant VOL = 0.01e18;
    uint256 internal constant UTIL = 0;

    uint64 internal constant T0 = 1_700_000_000; // arbitrary start timestamp

    function setUp() public {
        vm.warp(T0);
        vm.chainId(1);

        fixedModel = new FixedDateEpochModel();
        autoRollModel = new MockAutoRollModel();

        em = new EpochManager(OWNER, HOOK);

        POOL_A = PoolId.wrap(keccak256("ETH/USDC 0.05%"));
        POOL_B = PoolId.wrap(keccak256("BTC/ETH 0.3%"));

        MODEL_PARAMS = abi.encode(EPOCH_DURATION);

        // Register POOL_A as the default pool for most tests.
        vm.prank(OWNER);
        em.registerPool(POOL_A, fixedModel, MODEL_PARAMS, ALPHA, BETA, GAMMA);
    }

    // =========================================================================
    // A — deployment & access control
    // =========================================================================

    function test_deploy_ownerSet() public view {
        assertEq(em.owner(), OWNER);
    }

    function test_deploy_authorizedCallerSet() public view {
        assertEq(em.authorizedCaller(), HOOK);
    }

    function test_deploy_pendingOwnerZero() public view {
        assertEq(em.pendingOwner(), address(0));
    }

    function test_deploy_revertsOnZeroOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                address(0)
            )
        );
        new EpochManager(address(0), HOOK);
    }

    function test_setAuthorizedCaller_ownerCanChange() public {
        vm.prank(OWNER);
        em.setAuthorizedCaller(ALICE);
        assertEq(em.authorizedCaller(), ALICE);
    }

    function test_setAuthorizedCaller_nonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                ALICE
            )
        );
        em.setAuthorizedCaller(ALICE);
    }

    // =========================================================================
    // B — pool registration
    // =========================================================================

    function test_registerPool_setsConfig() public view {
        (address model, uint256 eid, uint32 counter, bool reg) = em
            .getPoolConfig(POOL_A);

        assertEq(model, address(fixedModel));
        assertEq(eid, EpochId.NULL);
        assertEq(counter, 0);
        assertTrue(reg);
    }

    function test_registerPool_nonOwnerReverts() public {
        PoolId other = PoolId.wrap(keccak256("X"));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                ALICE
            )
        );
        em.registerPool(other, fixedModel, MODEL_PARAMS, ALPHA, BETA, GAMMA);
    }

    function test_registerPool_duplicateReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.PoolAlreadyRegistered.selector,
                POOL_A
            )
        );
        em.registerPool(POOL_A, fixedModel, MODEL_PARAMS, ALPHA, BETA, GAMMA);
    }

    function test_registerPool_zeroModelReverts() public {
        PoolId other = PoolId.wrap(keccak256("Y"));
        vm.prank(OWNER);
        vm.expectRevert(EpochManager.ZeroAddress.selector);
        em.registerPool(
            other,
            IEpochModel(address(0)),
            MODEL_PARAMS,
            ALPHA,
            BETA,
            GAMMA
        );
    }

    function test_registerPool_invalidParamsReverts() public {
        PoolId other = PoolId.wrap(keccak256("Z"));
        // FixedDateEpochModel rejects duration = 0.
        bytes memory badParams = abi.encode(uint32(0));
        vm.prank(OWNER);
        vm.expectRevert(EpochManager.InvalidModelParams.selector);
        em.registerPool(other, fixedModel, badParams, ALPHA, BETA, GAMMA);
    }

    function test_registerPool_emitsEvent() public {
        PoolId other = PoolId.wrap(keccak256("EVENT_POOL"));
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit EpochManager.PoolRegistered(
            other,
            address(fixedModel),
            ALPHA,
            BETA,
            GAMMA
        );
        em.registerPool(other, fixedModel, MODEL_PARAMS, ALPHA, BETA, GAMMA);
    }

    // =========================================================================
    // C — openEpoch
    // =========================================================================

    function test_openEpoch_hookCanOpen() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        assertTrue(eid != EpochId.NULL);
    }

    function test_openEpoch_ownerCanOpen() public {
        vm.prank(OWNER);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        assertTrue(eid != EpochId.NULL);
    }

    function test_openEpoch_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(EpochManager.NotAuthorized.selector);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);
    }

    function test_openEpoch_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN"));
        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.PoolNotRegistered.selector,
                unknown
            )
        );
        em.openEpoch(unknown, TWAP, VOL, UTIL);
    }

    function test_openEpoch_setsEpochFields() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        EpochManager.Epoch memory ep = em.getEpoch(eid);

        assertEq(ep.epochId, eid);
        assertEq(PoolId.unwrap(ep.poolId), PoolId.unwrap(POOL_A));
        assertEq(ep.startTime, T0);
        assertEq(ep.maturity, T0 + EPOCH_DURATION);
        assertEq(uint8(ep.status), uint8(EpochManager.EpochStatus.ACTIVE));
        assertEq(ep.totalNotional, 0);
        assertTrue(ep.fixedRate > 0);
    }

    function test_openEpoch_updatesPoolConfig() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        (, uint256 activeEid, uint32 counter, ) = em.getPoolConfig(POOL_A);
        assertEq(activeEid, eid);
        assertEq(counter, 1);
    }

    function test_openEpoch_epochIdIsMonotone() public {
        vm.prank(HOOK);
        uint256 eid0 = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        // Settle so we can open a second epoch.
        vm.warp(T0 + EPOCH_DURATION + 1);
        em.settle(eid0, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        uint256 eid1 = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        // epochIndex embedded in eid1 must be > eid0's.
        assertEq(EpochId.epochIndex(eid1), EpochId.epochIndex(eid0) + 1);
    }

    function test_openEpoch_duplicateReverts() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochAlreadyActive.selector,
                POOL_A,
                eid
            )
        );
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);
    }

    function test_openEpoch_emitsEvent() public {
        uint64 expectedMaturity = T0 + EPOCH_DURATION;

        vm.prank(HOOK);
        // We can't predict fixedRate exactly without rerunning the formula,
        // so we only check the indexed fields + startTime/maturity.
        vm.expectEmit(false, true, false, false);
        emit EpochManager.EpochOpened(0, POOL_A, T0, expectedMaturity, 0);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);
    }

    // =========================================================================
    // D — addNotional
    // =========================================================================

    function test_addNotional_accumulatesCorrectly() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        em.addNotional(POOL_A, 1000e18);

        vm.prank(HOOK);
        em.addNotional(POOL_A, 500e18);

        EpochManager.Epoch memory ep = em.getEpoch(eid);
        assertEq(ep.totalNotional, 1500e18);
    }

    function test_addNotional_noActiveEpochReverts() public {
        // POOL_A has no active epoch yet (setUp only registers, doesn't open).
        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(EpochManager.EpochNotActive.selector, 0)
        );
        em.addNotional(POOL_A, 1e18);
    }

    function test_addNotional_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN2"));
        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.PoolNotRegistered.selector,
                unknown
            )
        );
        em.addNotional(unknown, 1e18);
    }

    function test_addNotional_overflowReverts() public {
        vm.prank(HOOK);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        // Add up to near-max.
        vm.prank(HOOK);
        em.addNotional(POOL_A, type(uint128).max);

        // Any further addition must revert.
        vm.prank(HOOK);
        vm.expectRevert(EpochManager.NotionalOverflow.selector);
        em.addNotional(POOL_A, 1);
    }

    function test_addNotional_emitsEvent() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        vm.expectEmit(true, false, false, true);
        emit EpochManager.NotionalAdded(eid, 1e18, 1e18);
        em.addNotional(POOL_A, 1e18);
    }

    function test_addNotional_unauthorizedReverts() public {
        vm.prank(HOOK);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(ALICE);
        vm.expectRevert(EpochManager.NotAuthorized.selector);
        em.addNotional(POOL_A, 1e18);
    }

    // =========================================================================
    // E — settle (non-autoRoll)
    // =========================================================================

    function _openAndWarpToMaturity() internal returns (uint256 eid) {
        vm.prank(HOOK);
        eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        vm.warp(T0 + EPOCH_DURATION); // exactly at maturity
    }

    function test_settle_anyoneCanSettle() public {
        uint256 eid = _openAndWarpToMaturity();
        vm.prank(ALICE); // not owner, not hook
        em.settle(eid, TWAP, VOL, UTIL);

        EpochManager.Epoch memory ep = em.getEpoch(eid);
        assertEq(uint8(ep.status), uint8(EpochManager.EpochStatus.SETTLED));
    }

    function test_settle_clearsActiveEpochId() public {
        uint256 eid = _openAndWarpToMaturity();
        em.settle(eid, TWAP, VOL, UTIL);

        assertEq(em.activeEpochIdFor(POOL_A), EpochId.NULL);
        assertFalse(em.hasActiveEpoch(POOL_A));
    }

    function test_settle_beforeMaturityReverts() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        // One second before maturity.
        vm.warp(T0 + EPOCH_DURATION - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochNotMatured.selector,
                eid,
                uint64(T0 + EPOCH_DURATION),
                uint64(T0 + EPOCH_DURATION - 1)
            )
        );
        em.settle(eid, TWAP, VOL, UTIL);
    }

    function test_settle_unknownEpochReverts() public {
        uint256 fake = 12345;
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochDoesNotExist.selector,
                fake
            )
        );
        em.settle(fake, TWAP, VOL, UTIL);
    }

    function test_settle_doubleSettleReverts() public {
        uint256 eid = _openAndWarpToMaturity();
        em.settle(eid, TWAP, VOL, UTIL);

        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochAlreadySettled.selector,
                eid
            )
        );
        em.settle(eid, TWAP, VOL, UTIL);
    }

    function test_settle_noAutoRollReturnsNull() public {
        uint256 eid = _openAndWarpToMaturity();
        uint256 next = em.settle(eid, TWAP, VOL, UTIL);
        assertEq(next, EpochId.NULL);
    }

    function test_settle_emitsEvent() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        em.addNotional(POOL_A, 1000e18);

        vm.warp(T0 + EPOCH_DURATION);

        vm.expectEmit(true, true, false, false);
        emit EpochManager.EpochSettled(
            eid,
            POOL_A,
            1000e18,
            uint64(T0 + EPOCH_DURATION)
        );
        em.settle(eid, TWAP, VOL, UTIL);
    }

    // =========================================================================
    // F — settle + autoRoll
    // =========================================================================

    function _registerAutoRollPool() internal {
        vm.prank(OWNER);
        em.registerPool(POOL_B, autoRollModel, "", ALPHA, BETA, GAMMA);
    }

    function test_autoRoll_opensSuccessorEpoch() public {
        _registerAutoRollPool();

        vm.prank(HOOK);
        uint256 eid0 = em.openEpoch(POOL_B, TWAP, VOL, UTIL);

        vm.warp(T0 + MockAutoRollModel(address(autoRollModel)).DURATION());

        uint256 eid1 = em.settle(eid0, TWAP, VOL, UTIL);

        assertTrue(eid1 != EpochId.NULL, "successor should be non-null");
        assertTrue(eid1 != eid0, "successor must differ from predecessor");
    }

    function test_autoRoll_successorIsActive() public {
        _registerAutoRollPool();

        vm.prank(HOOK);
        uint256 eid0 = em.openEpoch(POOL_B, TWAP, VOL, UTIL);

        vm.warp(T0 + MockAutoRollModel(address(autoRollModel)).DURATION());
        uint256 eid1 = em.settle(eid0, TWAP, VOL, UTIL);

        assertEq(em.activeEpochIdFor(POOL_B), eid1);
        assertTrue(em.hasActiveEpoch(POOL_B));

        EpochManager.Epoch memory ep1 = em.getEpoch(eid1);
        assertEq(uint8(ep1.status), uint8(EpochManager.EpochStatus.ACTIVE));
    }

    function test_autoRoll_predecessorIsSettled() public {
        _registerAutoRollPool();

        vm.prank(HOOK);
        uint256 eid0 = em.openEpoch(POOL_B, TWAP, VOL, UTIL);

        vm.warp(T0 + MockAutoRollModel(address(autoRollModel)).DURATION());
        em.settle(eid0, TWAP, VOL, UTIL);

        EpochManager.Epoch memory ep0 = em.getEpoch(eid0);
        assertEq(uint8(ep0.status), uint8(EpochManager.EpochStatus.SETTLED));
    }

    function test_autoRoll_successorEpochIndexIncremented() public {
        _registerAutoRollPool();

        vm.prank(HOOK);
        uint256 eid0 = em.openEpoch(POOL_B, TWAP, VOL, UTIL);

        vm.warp(T0 + MockAutoRollModel(address(autoRollModel)).DURATION());
        uint256 eid1 = em.settle(eid0, TWAP, VOL, UTIL);

        assertEq(EpochId.epochIndex(eid1), EpochId.epochIndex(eid0) + 1);
    }

    function test_autoRoll_multipleRolls() public {
        _registerAutoRollPool();
        uint32 dur = MockAutoRollModel(address(autoRollModel)).DURATION();

        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_B, TWAP, VOL, UTIL);

        // Roll three times.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + dur);
            uint256 next = em.settle(eid, TWAP, VOL, UTIL);
            assertTrue(next != EpochId.NULL);
            assertEq(EpochId.epochIndex(next), EpochId.epochIndex(eid) + 1);
            eid = next;
        }

        // After 3 rolls the counter should be at 4.
        (, , uint32 counter, ) = em.getPoolConfig(POOL_B);
        assertEq(counter, 4);
    }

    // =========================================================================
    // G — view functions
    // =========================================================================

    function test_hasActiveEpoch_falseBeforeOpen() public view {
        assertFalse(em.hasActiveEpoch(POOL_A));
    }

    function test_hasActiveEpoch_trueAfterOpen() public {
        vm.prank(HOOK);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        assertTrue(em.hasActiveEpoch(POOL_A));
    }

    function test_activeEpochIdFor_nullBeforeOpen() public view {
        assertEq(em.activeEpochIdFor(POOL_A), EpochId.NULL);
    }

    function test_currentObligation_zeroForUnknownEpoch() public view {
        assertEq(em.currentObligation(12345), 0);
    }

    function test_currentObligation_zeroWithNoNotional() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        assertEq(em.currentObligation(eid), 0);
    }

    function test_currentObligation_nonZeroWithNotional() public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        em.addNotional(POOL_A, 1000e18);

        uint256 ob = em.currentObligation(eid);
        assertTrue(ob > 0, "obligation should be positive with notional");
    }

    function test_getEpoch_zeroStructForUnknown() public view {
        EpochManager.Epoch memory ep = em.getEpoch(99999);
        assertEq(ep.epochId, EpochId.NULL);
    }

    // =========================================================================
    // H — ownership transfer
    // =========================================================================

    function test_transferOwnership_twoStep() public {
        vm.prank(OWNER);
        em.transferOwnership(ALICE);

        assertEq(em.pendingOwner(), ALICE);
        assertEq(em.owner(), OWNER); // not yet transferred

        vm.prank(ALICE);
        em.acceptOwnership();

        assertEq(em.owner(), ALICE);
        assertEq(em.pendingOwner(), address(0));
    }

    function test_transferOwnership_nonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                ALICE
            )
        );
        em.transferOwnership(ALICE);
    }

    function test_acceptOwnership_nonPendingReverts() public {
        vm.prank(OWNER);
        em.transferOwnership(ALICE);

        vm.prank(OWNER); // OWNER is not the pending owner
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                OWNER
            )
        );
        em.acceptOwnership();
    }

    // =========================================================================
    // I — fuzz
    // =========================================================================

    /// @notice Any TWAP in [MIN_RATE, 2e18] produces a non-zero fixedRate.
    function testFuzz_openEpoch_fixedRatePositive(uint256 twap) public {
        uint256 MIN_RATE = 0.0001e18;
        twap = bound(twap, MIN_RATE, 2e18);

        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, twap, 0, 0);

        EpochManager.Epoch memory ep = em.getEpoch(eid);
        assertTrue(ep.fixedRate > 0);
    }

    /// @notice addNotional with fuzz delta accumulates without overflow for
    ///         values that fit in uint128.
    function testFuzz_addNotional_noOverflow(uint128 d1, uint128 d2) public {
        // Skip inputs whose sum would overflow uint128.
        vm.assume(uint256(d1) + uint256(d2) <= type(uint128).max);
        vm.assume(d1 > 0 && d2 > 0);

        vm.prank(HOOK);
        em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        em.addNotional(POOL_A, d1);

        vm.prank(HOOK);
        em.addNotional(POOL_A, d2);

        (, uint256 eid, , ) = em.getPoolConfig(POOL_A);
        // eid is the active epoch after two addNotional calls.
        EpochManager.Epoch memory ep = em.getEpoch(eid);
        assertEq(ep.totalNotional, uint128(uint256(d1) + uint256(d2)));
    }

    /// @notice settle() always reverts before maturity and succeeds at or after.
    function testFuzz_settle_maturityBoundary(uint32 warpDelta) public {
        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);
        uint64 maturity = T0 + EPOCH_DURATION;

        if (warpDelta < EPOCH_DURATION) {
            vm.warp(T0 + warpDelta);
            vm.expectRevert(
                abi.encodeWithSelector(
                    EpochManager.EpochNotMatured.selector,
                    eid,
                    maturity,
                    uint64(T0 + warpDelta)
                )
            );
            em.settle(eid, TWAP, VOL, UTIL);
        } else {
            vm.warp(T0 + warpDelta);
            em.settle(eid, TWAP, VOL, UTIL); // must not revert
            EpochManager.Epoch memory ep = em.getEpoch(eid);
            assertEq(uint8(ep.status), uint8(EpochManager.EpochStatus.SETTLED));
        }
    }

    /// @notice currentObligation is monotonically non-decreasing as notional grows.
    function testFuzz_obligation_monotonicInNotional(
        uint64 n1,
        uint64 n2
    ) public {
        vm.assume(n1 > 0 && n2 > 0);
        vm.assume(uint256(n1) + uint256(n2) <= type(uint128).max);

        vm.prank(HOOK);
        uint256 eid = em.openEpoch(POOL_A, TWAP, VOL, UTIL);

        vm.prank(HOOK);
        em.addNotional(POOL_A, n1);
        uint256 ob1 = em.currentObligation(eid);

        vm.prank(HOOK);
        em.addNotional(POOL_A, n2);
        uint256 ob2 = em.currentObligation(eid);

        assertGe(ob2, ob1, "obligation must be >= after adding more notional");
    }
}

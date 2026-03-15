// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AuthorizedCaller} from "../../src/libraries/AuthorizedCaller.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";
import {EpochManager} from "../../src/core/EpochManager.sol";

/// @title YieldRouterTest
/// @notice Unit tests for YieldRouter covering accounting waterfall and
///         settlement zone logic.
///
/// Test organisation
/// -----------------
///   Section A  — deployment & governance
///   Section B  — ingest: waterfall arithmetic
///   Section C  — ingest: edge cases
///   Section D  — finalizeEpoch: Zone A (full coverage)
///   Section E  — finalizeEpoch: Zone B (buffer rescue)
///   Section F  — finalizeEpoch: Zone C (haircut)
///   Section G  — previewFinalization
///   Section H  — access control
///   Section I  — fuzz

// =============================================================================
// Minimal mock ERC-20
// =============================================================================

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// =============================================================================
// Minimal mock EpochManager (just satisfies the import; YieldRouter only
// stores it as immutable and doesn't call it in the paths we test here).
// =============================================================================

contract MockEpochManager {
    // No-op — YieldRouter stores this address but doesn't call it in ingest/finalize.
}

contract MockMaturityVault {
    function receiveSettlement(
        uint256 epochId,
        address token,
        uint128 fytTotal,
        uint128 vytTotal
    ) external {}
}

// =============================================================================
// Test contract
// =============================================================================

contract YieldRouterTest is Test {
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    YieldRouter internal yr;
    MockERC20 internal token;
    MockEpochManager internal mockEM;

    address internal constant OWNER = address(0xA110CE);
    address internal constant HOOK = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);
    address internal VAULT;

    PoolId internal POOL;

    // A non-zero epochId (as EpochId.encode() would produce).
    uint256 internal constant EPOCH_ID =
        (uint256(1) << 192) | (uint256(42) << 32) | uint256(0);

    uint256 internal constant WAD = 1e18;

    function setUp() public {
        vm.chainId(1);

        token = new MockERC20();
        mockEM = new MockEpochManager();

        yr = new YieldRouter(OWNER, HOOK, EpochManager(address(mockEM)));

        MockMaturityVault mockVault = new MockMaturityVault();
        VAULT = address(mockVault);

        vm.prank(OWNER);
        yr.setMaturityVault(VAULT);

        POOL = PoolId.wrap(keccak256("ETH/USDC 0.05%"));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Fund the YieldRouter with tokens and call ingest().
    function _ingest(uint128 feeAmount, uint128 obligation) internal {
        token.mint(address(yr), feeAmount);
        vm.prank(HOOK);
        yr.ingest(EPOCH_ID, POOL, address(token), feeAmount, obligation);
    }

    /// Call finalizeEpoch and return SettlementAmounts.
    function _finalize(
        uint128 obligation
    ) internal returns (YieldRouter.SettlementAmounts memory) {
        vm.prank(HOOK);
        return yr.finalizeEpoch(EPOCH_ID, POOL, address(token), obligation);
    }

    // =========================================================================
    // A — deployment & governance
    // =========================================================================

    function test_deploy_ownerSet() public view {
        assertEq(yr.owner(), OWNER);
    }

    function test_deploy_authorizedCallerSet() public view {
        assertEq(yr.authorizedCaller(), HOOK);
    }

    function test_deploy_defaultSkimRate() public view {
        assertEq(yr.bufferSkimRate(), 0.10e18);
    }

    function test_deploy_zeroOwnerReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                address(0)
            )
        );
        new YieldRouter(address(0), HOOK, EpochManager(address(mockEM)));
    }

    function test_setBufferSkimRate_ownerCanSet() public {
        vm.prank(OWNER);
        yr.setBufferSkimRate(0.15e18);
        assertEq(yr.bufferSkimRate(), 0.15e18);
    }

    function test_setBufferSkimRate_belowMinReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                YieldRouter.SkimRateOutOfBounds.selector,
                0.04e18
            )
        );
        yr.setBufferSkimRate(0.04e18);
    }

    function test_setBufferSkimRate_aboveMaxReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                YieldRouter.SkimRateOutOfBounds.selector,
                0.26e18
            )
        );
        yr.setBufferSkimRate(0.26e18);
    }

    function test_setMaturityVault_zeroAddressReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(YieldRouter.ZeroAddress.selector);
        yr.setMaturityVault(address(0));
    }

    // =========================================================================
    // B — ingest: waterfall arithmetic
    // =========================================================================

    /// Scenario: obligation = 100, fee = 60.
    /// fixedFill = 60, skim = 0, variable = 0.
    /// (No surplus so no skim, no variable.)
    function test_ingest_partialFixedFill() public {
        uint128 obligation = 100e18;
        uint128 fee = 60e18;

        _ingest(fee, obligation);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 60e18);
        assertEq(bal.variableAccrued, 0);
        assertEq(bal.reserveContrib, 0);
    }

    /// Scenario: obligation = 100, fee = 100 (exactly covered).
    /// fixedFill = 100, skim = 0, variable = 0.
    function test_ingest_exactCoverage_noSurplus() public {
        uint128 obligation = 100e18;
        uint128 fee = 100e18;

        _ingest(fee, obligation);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 100e18);
        assertEq(bal.variableAccrued, 0);
        assertEq(bal.reserveContrib, 0);
    }

    /// Scenario: obligation = 100, fee = 200.
    /// fixedFill = 100, surplus = 100.
    /// skim = 100 × 10% = 10 → reserveBuffer.
    /// variable = 90.
    function test_ingest_surplusTriggersSkimAndVariable() public {
        uint128 obligation = 100e18;
        uint128 fee = 200e18;

        _ingest(fee, obligation);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 100e18);
        assertEq(bal.variableAccrued, 90e18);
        assertEq(bal.reserveContrib, 10e18);
        assertEq(yr.getReserveBuffer(POOL), 10e18);
    }

    /// Multiple ingests accumulate correctly.
    /// Ingest 1: fee=60, obligation=100 → fixedFill=60
    /// Ingest 2: fee=80, obligation=100 → fixedFill=40 (gap), surplus=40
    ///           skim=40×10%=4, variable=36
    function test_ingest_multipleCallsAccumulate() public {
        uint128 obligation = 100e18;

        _ingest(60e18, obligation);
        _ingest(80e18, obligation);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 100e18); // 60 + 40
        assertEq(bal.variableAccrued, 36e18); // 40 - 4
        assertEq(bal.reserveContrib, 4e18); // 10% of 40
        assertEq(yr.getReserveBuffer(POOL), 4e18);
    }

    /// Once fixed tranche is full, all incoming fees split between skim and variable.
    /// Pre-fill obligation, then ingest more.
    function test_ingest_alreadyFullFixed_allGoesToSurplus() public {
        uint128 obligation = 100e18;

        _ingest(100e18, obligation); // fill fixed exactly
        _ingest(200e18, obligation); // all surplus: skim=20, variable=180

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 100e18);
        assertEq(bal.variableAccrued, 180e18);
        assertEq(bal.reserveContrib, 20e18);
        assertEq(yr.getReserveBuffer(POOL), 20e18);
    }

    /// heldFees tracks cumulative gross receipts.
    function test_ingest_heldFeesAccumulates() public {
        _ingest(60e18, 100e18);
        _ingest(80e18, 100e18);

        assertEq(yr.getHeldFees(POOL, address(token)), 140e18);
    }

    /// Zero feeAmount is a no-op.
    function test_ingest_zeroFeeIsNoop() public {
        vm.prank(HOOK);
        yr.ingest(EPOCH_ID, POOL, address(token), 0, 100e18);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 0);
    }

    // =========================================================================
    // C — ingest: edge cases
    // =========================================================================

    /// Skim with updated rate (20%).
    function test_ingest_customSkimRate() public {
        vm.prank(OWNER);
        yr.setBufferSkimRate(0.20e18);

        _ingest(200e18, 100e18); // surplus = 100, skim = 20, variable = 80

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.reserveContrib, 20e18);
        assertEq(bal.variableAccrued, 80e18);
    }

    /// Zero obligation means all fees are surplus (no fixed fill).
    function test_ingest_zeroObligation_allSurplus() public {
        _ingest(100e18, 0);

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);
        assertEq(bal.fixedAccrued, 0);
        // skim = 100 × 10% = 10, variable = 90
        assertEq(bal.reserveContrib, 10e18);
        assertEq(bal.variableAccrued, 90e18);
    }

    // =========================================================================
    // D — finalizeEpoch: Zone A (full coverage)
    // =========================================================================

    function test_finalizeEpoch_zoneA_fullCoverage() public {
        uint128 obligation = 100e18;
        _ingest(200e18, obligation); // fixedAccrued=100, variable=90, skim=10

        YieldRouter.SettlementAmounts memory result = _finalize(obligation);

        assertEq(result.fytAmount, 100e18);
        assertEq(result.vytAmount, 90e18);
        assertEq(result.zone, 0);
    }

    function test_finalizeEpoch_zoneA_transfersToVault() public {
        _ingest(200e18, 100e18);
        _finalize(100e18);

        // Vault should hold fyt + vyt = 100 + 90 = 190
        assertEq(token.balanceOf(VAULT), 190e18);
    }

    function test_finalizeEpoch_zoneA_heldFeesDecremented() public {
        _ingest(200e18, 100e18);
        _finalize(100e18);

        // heldFees started at 200, transferred 190 out → 10 remaining (the skim)
        assertEq(yr.getHeldFees(POOL, address(token)), 10e18);
    }

    function test_finalizeEpoch_zoneA_bufferUntouched() public {
        _ingest(200e18, 100e18); // skim = 10 into buffer
        uint128 bufBefore = yr.getReserveBuffer(POOL);
        _finalize(100e18);
        // Buffer should be unchanged — Zone A doesn't touch it
        assertEq(yr.getReserveBuffer(POOL), bufBefore);
    }

    function test_finalizeEpoch_zoneA_emitsEvent() public {
        _ingest(200e18, 100e18);

        vm.prank(HOOK);
        vm.expectEmit(true, true, false, true);
        emit YieldRouter.EpochFinalized(EPOCH_ID, POOL, 100e18, 90e18, 0);
        yr.finalizeEpoch(EPOCH_ID, POOL, address(token), 100e18);
    }

    // =========================================================================
    // E — finalizeEpoch: Zone B (buffer rescue)
    // =========================================================================

    function test_finalizeEpoch_zoneB_bufferCoversShortfall() public {
        // Build up a buffer from a previous "epoch" on the same pool.
        // We simulate this by ingesting with a different epochId first.
        uint256 prevEpochId = EPOCH_ID - 1;
        token.mint(address(yr), 200e18);
        vm.prank(HOOK);
        yr.ingest(prevEpochId, POOL, address(token), 200e18, 100e18);
        // buffer now has 10 (skim from 100 surplus)

        // Now current epoch: only 80 fees came in against 100 obligation.
        _ingest(80e18, 100e18); // fixedAccrued=80, variable=0, skim=0

        // Buffer = 10, shortfall = 20 > buffer → Zone C actually.
        // Let's use obligation=85 so shortfall=5 which buffer covers.
        uint128 obligation = 85e18;
        // Re-do: ingest 80 against 85 obligation
        // Need fresh state — use a fresh epoch
        uint256 epochB = EPOCH_ID + 1;
        token.mint(address(yr), 80e18);
        vm.prank(HOOK);
        yr.ingest(epochB, POOL, address(token), 80e18, 85e18);
        // fixedAccrued=80, shortfall=5, buffer=10 ≥ 5 → Zone B

        vm.prank(HOOK);
        YieldRouter.SettlementAmounts memory result = yr.finalizeEpoch(
            epochB,
            POOL,
            address(token),
            85e18
        );

        assertEq(result.fytAmount, 85e18); // made whole
        assertEq(result.vytAmount, 0);
        assertEq(result.zone, 1);
    }

    function test_finalizeEpoch_zoneB_bufferDecremented() public {
        // Seed the buffer: 200 fee vs 100 obligation → skim = 10.
        _ingest(200e18, 100e18);
        uint128 bufBefore = yr.getReserveBuffer(POOL); // 10

        // New epoch: 90 fee, obligation 100, shortfall 10.
        uint256 epoch2 = EPOCH_ID + 1;
        token.mint(address(yr), 90e18);
        vm.prank(HOOK);
        yr.ingest(epoch2, POOL, address(token), 90e18, 100e18);
        // fixedAccrued=90, shortfall=10, buffer=10 → Zone B

        vm.prank(HOOK);
        yr.finalizeEpoch(epoch2, POOL, address(token), 100e18);

        assertEq(yr.getReserveBuffer(POOL), bufBefore - 10e18);
    }

    // =========================================================================
    // F — finalizeEpoch: Zone C (haircut)
    // =========================================================================

    function test_finalizeEpoch_zoneC_haircutApplied() public {
        // 60 fees, obligation 100, buffer 0 → Zone C.
        _ingest(60e18, 100e18);

        YieldRouter.SettlementAmounts memory result = _finalize(100e18);

        // FYT gets fixedAccrued (60) + buffer (0) = 60.
        assertEq(result.fytAmount, 60e18);
        assertEq(result.vytAmount, 0);
        assertEq(result.zone, 2);
    }

    function test_finalizeEpoch_zoneC_bufferDepleted() public {
        // Seed buffer: 200 fees, obligation 100 → skim 10.
        _ingest(200e18, 100e18);

        // New epoch: 40 fees, obligation 100.
        // shortfall=60, buffer=10 < 60 → Zone C.
        uint256 epoch2 = EPOCH_ID + 1;
        token.mint(address(yr), 40e18);
        vm.prank(HOOK);
        yr.ingest(epoch2, POOL, address(token), 40e18, 100e18);

        vm.prank(HOOK);
        YieldRouter.SettlementAmounts memory result = yr.finalizeEpoch(
            epoch2,
            POOL,
            address(token),
            100e18
        );

        // FYT gets 40 + 10 (full buffer) = 50.
        assertEq(result.fytAmount, 50e18);
        assertEq(result.vytAmount, 0);
        assertEq(result.zone, 2);
        assertEq(yr.getReserveBuffer(POOL), 0); // fully depleted
    }

    function test_finalizeEpoch_zoneC_emitsEvent() public {
        _ingest(60e18, 100e18);

        vm.prank(HOOK);
        vm.expectEmit(true, true, false, true);
        emit YieldRouter.EpochFinalized(EPOCH_ID, POOL, 60e18, 0, 2);
        yr.finalizeEpoch(EPOCH_ID, POOL, address(token), 100e18);
    }

    // =========================================================================
    // G — previewFinalization
    // =========================================================================

    function test_preview_matchesActualZoneA() public {
        _ingest(200e18, 100e18);

        YieldRouter.SettlementAmounts memory preview = yr.previewFinalization(
            EPOCH_ID,
            POOL,
            100e18
        );

        assertEq(preview.fytAmount, 100e18);
        assertEq(preview.vytAmount, 90e18);
        assertEq(preview.zone, 0);
    }

    function test_preview_noStateChange() public {
        _ingest(200e18, 100e18);

        uint128 bufBefore = yr.getReserveBuffer(POOL);
        yr.previewFinalization(EPOCH_ID, POOL, 100e18);
        assertEq(yr.getReserveBuffer(POOL), bufBefore);
    }

    // =========================================================================
    // H — access control
    // =========================================================================

    function test_ingest_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(AuthorizedCaller.NotAuthorized.selector);
        yr.ingest(EPOCH_ID, POOL, address(token), 100e18, 100e18);
    }

    function test_finalizeEpoch_unauthorizedReverts() public {
        _ingest(100e18, 100e18);

        vm.prank(ALICE);
        vm.expectRevert(AuthorizedCaller.NotAuthorized.selector);
        yr.finalizeEpoch(EPOCH_ID, POOL, address(token), 100e18);
    }

    function test_finalizeEpoch_noVaultReverts() public {
        // Deploy a fresh router with no vault set.
        YieldRouter yr2 = new YieldRouter(
            OWNER,
            HOOK,
            EpochManager(address(mockEM))
        );

        token.mint(address(yr2), 100e18);
        vm.prank(HOOK);
        yr2.ingest(EPOCH_ID, POOL, address(token), 100e18, 100e18);

        vm.prank(HOOK);
        vm.expectRevert(YieldRouter.MaturityVaultNotSet.selector);
        yr2.finalizeEpoch(EPOCH_ID, POOL, address(token), 100e18);
    }

    // =========================================================================
    // I — fuzz
    // =========================================================================

    /// Waterfall invariant: fixedFill + skim + variable == feeAmount always.
    function testFuzz_ingest_waterfallExhaustive(
        uint64 fee,
        uint64 obligation
    ) public {
        vm.assume(fee > 0);

        _ingest(uint128(fee), uint128(obligation));

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);

        uint256 total = uint256(bal.fixedAccrued) +
            uint256(bal.variableAccrued) +
            uint256(bal.reserveContrib);

        assertEq(
            total,
            uint256(fee),
            "waterfall must exhaust feeAmount exactly"
        );
    }

    /// Zone classification is consistent: Zone A iff fixedAccrued >= obligation.
    function testFuzz_finalize_zoneClassification(
        uint64 fee,
        uint64 obligation
    ) public {
        vm.assume(fee > 0);
        vm.assume(obligation > 0);

        _ingest(uint128(fee), uint128(obligation));

        YieldRouter.SettlementAmounts memory preview = yr.previewFinalization(
            EPOCH_ID,
            POOL,
            uint128(obligation)
        );

        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(EPOCH_ID);

        if (bal.fixedAccrued >= uint128(obligation)) {
            assertEq(preview.zone, 0, "should be Zone A");
        } else if (
            yr.getReserveBuffer(POOL) >= uint128(obligation) - bal.fixedAccrued
        ) {
            assertEq(preview.zone, 1, "should be Zone B");
        } else {
            assertEq(preview.zone, 2, "should be Zone C");
        }
    }

    /// FYT amount never exceeds fixedObligation.
    function testFuzz_finalize_fytNeverExceedsObligation(
        uint64 fee,
        uint64 obligation
    ) public {
        vm.assume(fee > 0);
        vm.assume(obligation > 0);

        _ingest(uint128(fee), uint128(obligation));

        YieldRouter.SettlementAmounts memory preview = yr.previewFinalization(
            EPOCH_ID,
            POOL,
            uint128(obligation)
        );

        assertLe(
            preview.fytAmount,
            uint128(obligation),
            "FYT must never exceed obligation"
        );
    }

    /// VYT is non-zero iff Zone A.
    function testFuzz_finalize_vytOnlyInZoneA(
        uint64 fee,
        uint64 obligation
    ) public {
        vm.assume(fee > 0);
        vm.assume(obligation > 0);

        _ingest(uint128(fee), uint128(obligation));

        YieldRouter.SettlementAmounts memory preview = yr.previewFinalization(
            EPOCH_ID,
            POOL,
            uint128(obligation)
        );

        if (preview.zone != 0) {
            assertEq(preview.vytAmount, 0, "VYT must be zero outside Zone A");
        }
    }
}

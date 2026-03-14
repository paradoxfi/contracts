// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Test}   from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {PositionId}      from "../../src/libraries/PositionId.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";

/// @title PositionManagerTest
/// @notice Unit and fuzz tests for PositionManager.
///
/// Test organisation
/// -----------------
///   Section A  — deployment & access control
///   Section B  — mint: happy path
///   Section C  — mint: revert cases
///   Section D  — mint: positionId structure
///   Section E  — markExited
///   Section F  — view functions
///   Section G  — ownership transfer
///   Section H  — fuzz

contract PositionManagerTest is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    PositionManager internal pm;

    address internal constant OWNER = address(0xA110CE);
    address internal constant HOOK  = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB   = address(0xB0B);

    PoolId internal POOL_A;
    PoolId internal POOL_B;

    // Canonical mint inputs.
    int24   internal constant TICK_LOWER  = -100;
    int24   internal constant TICK_UPPER  = 100;
    uint128 internal constant LIQUIDITY   = 1_000_000e18;
    uint128 internal constant NOTIONAL    = 5_000e18;
    uint64  internal constant FIXED_RATE  = 0.05e18; // 5% WAD
    // epochId: any non-zero value (EpochManager produces these; we don't recompute here)
    uint256 internal constant EPOCH_ID    = (uint256(1) << 192) | (uint256(1) << 32); // chain=1, pool≠0, idx=0

    uint64 internal constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        vm.chainId(1);

        pm = new PositionManager(OWNER, HOOK);

        POOL_A = PoolId.wrap(keccak256("ETH/USDC 0.05%"));
        POOL_B = PoolId.wrap(keccak256("BTC/ETH 0.3%"));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mint(address recipient) internal returns (uint256) {
        vm.prank(HOOK);
        return pm.mint(
            recipient, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
    }

    function _mint(address recipient, PoolId pool) internal returns (uint256) {
        vm.prank(HOOK);
        return pm.mint(
            recipient, pool, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
    }

    // =========================================================================
    // A — deployment & access control
    // =========================================================================

    function test_deploy_ownerSet() public view {
        assertEq(pm.owner(), OWNER);
    }

    function test_deploy_authorizedCallerSet() public view {
        assertEq(pm.authorizedCaller(), HOOK);
    }

    function test_deploy_zeroOwnerReverts() public {
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManager(address(0), HOOK);
    }

    function test_deploy_nameAndSymbol() public view {
        assertEq(pm.name(),   "Paradox Fi Position");
        assertEq(pm.symbol(), "PDX-POS");
    }

    function test_setAuthorizedCaller_ownerCanChange() public {
        vm.prank(OWNER);
        pm.setAuthorizedCaller(ALICE);
        assertEq(pm.authorizedCaller(), ALICE);
    }

    function test_setAuthorizedCaller_nonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                ALICE
            )
        );
        pm.setAuthorizedCaller(ALICE);
    }

    function test_mint_ownerCanAlsoMint() public {
        vm.prank(OWNER);
        uint256 pid = pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
        assertEq(pm.ownerOf(pid), ALICE);
    }

    function test_mint_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(PositionManager.NotAuthorized.selector);
        pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
    }

    // =========================================================================
    // B — mint: happy path
    // =========================================================================

    function test_mint_mintsNFTToRecipient() public {
        uint256 pid = _mint(ALICE);
        assertEq(pm.ownerOf(pid), ALICE);
    }

    function test_mint_storesAllFields() public {
        uint256 pid = _mint(ALICE);
        PositionManager.Position memory pos = pm.getPosition(pid);

        assertEq(PoolId.unwrap(pos.poolId), PoolId.unwrap(POOL_A));
        assertEq(pos.epochId,       EPOCH_ID);
        assertEq(pos.tickLower,     TICK_LOWER);
        assertEq(pos.tickUpper,     TICK_UPPER);
        assertEq(pos.liquidity,     LIQUIDITY);
        assertEq(pos.notional,      NOTIONAL);
        assertEq(pos.fixedRate,     FIXED_RATE);
        assertEq(pos.mintTimestamp, T0);
        assertFalse(pos.exited);
    }

    function test_mint_incrementsPoolCounter() public {
        assertEq(pm.poolCounter(POOL_A), 0);
        _mint(ALICE);
        assertEq(pm.poolCounter(POOL_A), 1);
        _mint(BOB);
        assertEq(pm.poolCounter(POOL_A), 2);
    }

    function test_mint_counterIndependentAcrossPools() public {
        _mint(ALICE, POOL_A);
        _mint(ALICE, POOL_A);
        _mint(BOB,   POOL_B);

        assertEq(pm.poolCounter(POOL_A), 2);
        assertEq(pm.poolCounter(POOL_B), 1);
    }

    function test_mint_emitsEvent() public {
        vm.prank(HOOK);
        vm.expectEmit(false, true, true, true);
        emit PositionManager.PositionMinted(0, ALICE, POOL_A, EPOCH_ID, NOTIONAL, FIXED_RATE);
        pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
    }

    function test_mint_consecutiveMintsDifferentIds() public {
        uint256 pid1 = _mint(ALICE);
        uint256 pid2 = _mint(BOB);
        assertTrue(pid1 != pid2);
    }

    // =========================================================================
    // C — mint: revert cases
    // =========================================================================

    function test_mint_zeroRecipientReverts() public {
        vm.prank(HOOK);
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        pm.mint(
            address(0), POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, NOTIONAL, FIXED_RATE
        );
    }

    function test_mint_zeroLiquidityReverts() public {
        vm.prank(HOOK);
        vm.expectRevert(PositionManager.ZeroLiquidity.selector);
        pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, 0, NOTIONAL, FIXED_RATE
        );
    }

    function test_mint_zeroNotionalReverts() public {
        vm.prank(HOOK);
        vm.expectRevert(PositionManager.ZeroNotional.selector);
        pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            TICK_LOWER, TICK_UPPER, LIQUIDITY, 0, FIXED_RATE
        );
    }

    // =========================================================================
    // D — mint: positionId structure
    // =========================================================================

    function test_positionId_encodesChainId() public {
        uint256 pid = _mint(ALICE);
        assertEq(PositionId.chainId(pid), uint64(block.chainid));
    }

    function test_positionId_encodesPoolId() public {
        uint256 pid = _mint(ALICE);
        assertEq(
            PositionId.poolIdTruncated(pid),
            uint160(uint256(PoolId.unwrap(POOL_A)))
        );
    }

    function test_positionId_counterStartsAtOne() public {
        uint256 pid = _mint(ALICE);
        assertEq(PositionId.counter(pid), 1);
    }

    function test_positionId_secondMintCounterIsTwo() public {
        _mint(ALICE);
        uint256 pid2 = _mint(BOB);
        assertEq(PositionId.counter(pid2), 2);
    }

    function test_positionId_differentPoolsDifferentIds() public {
        uint256 pidA = _mint(ALICE, POOL_A);
        uint256 pidB = _mint(ALICE, POOL_B);
        assertTrue(pidA != pidB);
        // Both have counter == 1 but different poolId fields
        assertEq(PositionId.counter(pidA), 1);
        assertEq(PositionId.counter(pidB), 1);
    }

    function test_positionId_neverNull() public {
        uint256 pid = _mint(ALICE);
        assertTrue(pid != PositionId.NULL);
    }

    // =========================================================================
    // E — markExited
    // =========================================================================

    function test_markExited_setsExitedFlag() public {
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        pm.markExited(pid);

        PositionManager.Position memory pos = pm.getPosition(pid);
        assertTrue(pos.exited);
    }

    function test_markExited_emitsEvent() public {
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        vm.expectEmit(true, true, false, false);
        emit PositionManager.PositionExited(pid, ALICE);
        pm.markExited(pid);
    }

    function test_markExited_nonExistentReverts() public {
        uint256 fake = 99999;
        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.PositionDoesNotExist.selector, fake)
        );
        pm.markExited(fake);
    }

    function test_markExited_alreadyExitedReverts() public {
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        pm.markExited(pid);

        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.PositionAlreadyExited.selector, pid)
        );
        pm.markExited(pid);
    }

    function test_markExited_unauthorizedReverts() public {
        uint256 pid = _mint(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(PositionManager.NotAuthorized.selector);
        pm.markExited(pid);
    }

    function test_markExited_doesNotBurnNFT() public {
        // NFT must survive exit — owner needs it to redeem from MaturityVault.
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        pm.markExited(pid);

        assertEq(pm.ownerOf(pid), ALICE);
    }

    function test_markExited_nftTransferableAfterExit() public {
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        pm.markExited(pid);

        // Alice can still transfer the (exited) NFT to Bob.
        vm.prank(ALICE);
        pm.transferFrom(ALICE, BOB, pid);

        assertEq(pm.ownerOf(pid), BOB);
    }

    // =========================================================================
    // F — view functions
    // =========================================================================

    function test_getPosition_revertsForUnknown() public {
        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.PositionDoesNotExist.selector, 42)
        );
        pm.getPosition(42);
    }

    function test_isActive_trueAfterMint() public {
        uint256 pid = _mint(ALICE);
        assertTrue(pm.isActive(pid));
    }

    function test_isActive_falseAfterExit() public {
        uint256 pid = _mint(ALICE);

        vm.prank(HOOK);
        pm.markExited(pid);

        assertFalse(pm.isActive(pid));
    }

    function test_isActive_falseForUnknown() public view {
        assertFalse(pm.isActive(99999));
    }

    function test_poolCounter_zeroBeforeAnyMint() public view {
        assertEq(pm.poolCounter(POOL_A), 0);
    }

    // =========================================================================
    // G — ownership transfer
    // =========================================================================

    function test_ownershipTransfer_twoStep() public {
        vm.prank(OWNER);
        pm.transferOwnership(ALICE);

        assertEq(pm.pendingOwner(), ALICE);
        assertEq(pm.owner(), OWNER);

        vm.prank(ALICE);
        pm.acceptOwnership();

        assertEq(pm.owner(), ALICE);
        assertEq(pm.pendingOwner(), address(0));
    }

    function test_ownershipTransfer_nonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                ALICE
            )
        );
        pm.transferOwnership(ALICE);
    }

    function test_ownershipTransfer_zeroAddressReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        pm.transferOwnership(address(0));
    }

    function test_acceptOwnership_nonPendingReverts() public {
        vm.prank(OWNER);
        pm.transferOwnership(ALICE);

        vm.prank(BOB);
        vm.expectRevert(PositionManager.NotAuthorized.selector);
        pm.acceptOwnership();
    }

    // =========================================================================
    // H — fuzz
    // =========================================================================

    /// @notice positionId counter increments correctly for any number of mints
    ///         on the same pool.
    function testFuzz_mint_counterMonotone(uint8 n) public {
        vm.assume(n > 0 && n < 50); // keep gas bounded

        for (uint256 i = 0; i < n; i++) {
            uint256 pid = _mint(ALICE);
            assertEq(PositionId.counter(pid), uint32(i + 1));
        }
        assertEq(pm.poolCounter(POOL_A), uint32(n));
    }

    /// @notice Every minted positionId is unique (no two NFTs share a tokenId).
    function testFuzz_mint_uniqueIds(uint8 n) public {
        vm.assume(n > 1 && n < 30);

        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = _mint(ALICE);
        }

        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                assertTrue(ids[i] != ids[j], "duplicate positionId detected");
            }
        }
    }

    /// @notice Stored fields exactly match the inputs for any valid mint.
    function testFuzz_mint_fieldsMatchInputs(
        int24   tickLow,
        int24   tickHigh,
        uint128 liq,
        uint128 notional,
        uint64  rate
    ) public {
        vm.assume(liq > 0);
        vm.assume(notional > 0);
        vm.assume(tickLow < tickHigh);

        vm.prank(HOOK);
        uint256 pid = pm.mint(
            ALICE, POOL_A, EPOCH_ID,
            tickLow, tickHigh, liq, notional, rate
        );

        PositionManager.Position memory pos = pm.getPosition(pid);

        assertEq(pos.tickLower,  tickLow);
        assertEq(pos.tickUpper,  tickHigh);
        assertEq(pos.liquidity,  liq);
        assertEq(pos.notional,   notional);
        assertEq(pos.fixedRate,  rate);
        assertFalse(pos.exited);
    }
}

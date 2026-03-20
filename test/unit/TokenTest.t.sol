// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {FYToken} from "../../src/tokens/FYToken.sol";
import {VYToken} from "../../src/tokens/VYToken.sol";

/// @title TokenTest
/// @notice Unit tests for FYToken and VYToken.
///
/// Architecture notes (post-refactor):
///   FYToken:
///     - tokenId = positionId (NOT epochId)
///     - amount  = halfNotional (notional / 2)
///     - mint(to, positionId, PositionData) registers metadata + mints halfNotional
///     - burn(from, positionId, amount) — decrements epochPositionCount when supply → 0
///     - epochPositionCount(epochId) — count of positions in an epoch
///
///   VYToken:
///     - tokenId = positionId (same as FYToken)
///     - amount  = 1 (always)
///     - constructor takes FYToken address (reads position metadata from FYT)
///     - mint(to, positionId) — no epochId param, no amount param
///     - burn(from, positionId) — no epochId param
///     - no epochSupply — use fyt.epochPositionCount() instead
///
/// Test organisation
/// -----------------
///   Section A  — FYToken: deployment & roles
///   Section B  — FYToken: mint (with PositionData)
///   Section C  — FYToken: burn + epochPositionCount
///   Section D  — FYToken: totalSupply (ERC1155Supply)
///   Section E  — FYToken: epochPositionCount tracking
///   Section F  — FYToken: transfer
///   Section G  — VYToken: deployment & roles
///   Section H  — VYToken: mint
///   Section I  — VYToken: burn
///   Section J  — VYToken: transfer
///   Section K  — Cross-token: FYT and VYT positionId consistency
///   Section L  — Fuzz

// =============================================================================
// ERC1155Receiver stub — allows test contract to receive ERC1155 tokens
// =============================================================================

contract TokenRecipient is ERC1155Holder {}

contract TokenTest is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    FYToken internal fyt;
    VYToken internal vyt;

    address internal constant ADMIN   = address(0xAD);
    address internal constant MINTER  = address(0x1111);
    address internal constant BURNER1 = address(0x2222); // e.g. MaturityVault
    address internal constant BURNER2 = address(0x3333); // second authorized burner
    address internal ALICE;
    address internal BOB;

    // Canonical packed IDs.
    // EpochId layout:    [chainId=1 (64b)][poolId-like (160b)][epochIndex (32b)]
    // PositionId layout: same — lower 32b is the deposit counter
    uint256 internal constant EPOCH_ID_0  = (uint256(1) << 192) | (uint256(42) << 32) | 0;
    uint256 internal constant EPOCH_ID_1  = (uint256(1) << 192) | (uint256(42) << 32) | 1;
    uint256 internal constant POSITION_A  = (uint256(1) << 192) | (uint256(42) << 32) | 1;
    uint256 internal constant POSITION_B  = (uint256(1) << 192) | (uint256(42) << 32) | 2;
    uint256 internal constant POSITION_C  = (uint256(1) << 192) | (uint256(42) << 32) | 3;

    // Canonical pool reference used in PositionData.
    bytes32 internal constant POOL_ID = keccak256("TEST_POOL");

    address[] internal BURNERS;

    function setUp() public {
        // Use ERC1155Holder contracts as token holders so safeTransferFrom works.
        ALICE = address(new TokenRecipient());
        BOB   = address(new TokenRecipient());

        BURNERS = new address[](2);
        BURNERS[0] = BURNER1;
        BURNERS[1] = BURNER2;

        fyt = new FYToken(ADMIN, MINTER, BURNERS, "https://paradox.fi/fyt/{id}");
        vyt = new VYToken(ADMIN, MINTER, BURNERS, "https://paradox.fi/vyt/{id}", fyt);
    }

    // -------------------------------------------------------------------------
    // Helper: build a PositionData struct
    // -------------------------------------------------------------------------

    function _makePosition(
        uint256 epochId,
        uint128 liquidity
    ) internal pure returns (FYToken.PositionData memory) {
        return FYToken.PositionData({
            poolId:       POOL_ID,
            tickLower:    -100,
            tickUpper:     100,
            liquidity:    liquidity,
            halfNotional: liquidity / 2,
            epochId:      epochId
        });
    }

    /// Mint FYT for a position. Returns amount minted (= halfNotional).
    function _mintFYT(address to, uint256 positionId, uint256 epochId, uint128 liquidity)
        internal returns (uint128 halfNotional)
    {
        FYToken.PositionData memory data = _makePosition(epochId, liquidity);
        vm.prank(MINTER);
        fyt.mint(to, positionId, data);
        return data.halfNotional;
    }

    /// Mint VYT (amount = 1) to `to` for `positionId`.
    function _mintVYT(address to, uint256 positionId) internal {
        vm.prank(MINTER);
        vyt.mint(to, positionId);
    }

    // =========================================================================
    // A — FYToken: deployment & roles
    // =========================================================================

    function test_fyt_adminHasAdminRole() public view {
        assertTrue(fyt.hasRole(fyt.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_fyt_minterHasMinterRole() public view {
        assertTrue(fyt.hasRole(fyt.MINTER_ROLE(), MINTER));
    }

    function test_fyt_burnersHaveBurnerRole() public view {
        assertTrue(fyt.hasRole(fyt.BURNER_ROLE(), BURNER1));
        assertTrue(fyt.hasRole(fyt.BURNER_ROLE(), BURNER2));
    }

    function test_fyt_nameAndSymbol() public view {
        assertEq(fyt.name(),   "Paradox Fi Fixed Yield Token");
        assertEq(fyt.symbol(), "FYT");
    }

    function test_fyt_adminCanGrantMinterRole() public {
        vm.prank(ADMIN);
        fyt.grantRole(fyt.MINTER_ROLE(), ALICE);
        assertTrue(fyt.hasRole(fyt.MINTER_ROLE(), ALICE));
    }

    function test_fyt_nonAdminCannotGrantRole() public {
        vm.prank(ALICE);
        vm.expectRevert();
        fyt.grantRole(fyt.MINTER_ROLE(), ALICE);
    }

    // =========================================================================
    // B — FYToken: mint
    // =========================================================================

    function test_fyt_mint_minterCanMint() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        // amount = halfNotional = 1_000e18
        assertEq(fyt.balanceOf(ALICE, POSITION_A), 1_000e18);
    }

    function test_fyt_mint_amountIsHalfNotional() public {
        uint128 liquidity = 2_000e18;
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, liquidity);
        assertEq(fyt.balanceOf(ALICE, POSITION_A), liquidity / 2);
    }

    function test_fyt_mint_storesPositionMetadata() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);

        FYToken.PositionData memory pos = fyt.getPosition(POSITION_A);
        assertEq(pos.poolId,       POOL_ID);
        assertEq(pos.tickLower,    -100);
        assertEq(pos.tickUpper,     100);
        assertEq(pos.liquidity,    2_000e18);
        assertEq(pos.halfNotional, 1_000e18);
        assertEq(pos.epochId,      EPOCH_ID_0);
    }

    function test_fyt_mint_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        fyt.mint(ALICE, POSITION_A, _makePosition(EPOCH_ID_0, 1_000e18));
    }

    function test_fyt_mint_duplicatePositionReverts() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 1_000e18);
        vm.prank(MINTER);
        vm.expectRevert(
            abi.encodeWithSelector(FYToken.PositionAlreadyRegistered.selector, POSITION_A)
        );
        fyt.mint(ALICE, POSITION_A, _makePosition(EPOCH_ID_0, 2_000e18));
    }

    function test_fyt_mint_multiplePositionsSameEpoch() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintFYT(BOB,   POSITION_B, EPOCH_ID_0, 4_000e18);

        assertEq(fyt.balanceOf(ALICE, POSITION_A), 1_000e18);
        assertEq(fyt.balanceOf(BOB,   POSITION_B), 2_000e18);
    }

    function test_fyt_mint_positionsAcrossDifferentEpochs() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintFYT(ALICE, POSITION_B, EPOCH_ID_1, 4_000e18);

        assertEq(fyt.balanceOf(ALICE, POSITION_A), 1_000e18);
        assertEq(fyt.balanceOf(ALICE, POSITION_B), 2_000e18);
        assertEq(fyt.getPosition(POSITION_A).epochId, EPOCH_ID_0);
        assertEq(fyt.getPosition(POSITION_B).epochId, EPOCH_ID_1);
    }

    // =========================================================================
    // C — FYToken: burn + epochPositionCount
    // =========================================================================

    function test_fyt_burn_burner1CanBurn() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        vm.prank(BURNER1);
        fyt.burn(ALICE, POSITION_A, 1_000e18);
        assertEq(fyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_fyt_burn_burner2CanBurn() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        vm.prank(BURNER2);
        fyt.burn(ALICE, POSITION_A, 1_000e18);
        assertEq(fyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_fyt_burn_minterCannotBurn() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        vm.prank(MINTER);
        vm.expectRevert();
        fyt.burn(ALICE, POSITION_A, 1_000e18);
    }

    function test_fyt_burn_unauthorizedReverts() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        vm.prank(ALICE);
        vm.expectRevert();
        fyt.burn(ALICE, POSITION_A, 1_000e18);
    }

    function test_fyt_burn_decrementsEpochPositionCount_whenSupplyZero() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);

        // Partial burn — supply not yet zero, count unchanged.
        vm.prank(BURNER1);
        fyt.burn(ALICE, POSITION_A, 500e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);

        // Full burn — supply hits zero, count decrements.
        vm.prank(BURNER1);
        fyt.burn(ALICE, POSITION_A, 500e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 0);
    }

    // =========================================================================
    // D — FYToken: totalSupply (ERC1155Supply)
    // =========================================================================

    function test_fyt_totalSupply_tracksMintsAndBurns() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18); // +1000
        _mintFYT(BOB,   POSITION_B, EPOCH_ID_0, 2_000e18); // +1000 (different positionId)

        // totalSupply is per positionId, not per epochId.
        assertEq(fyt.totalSupply(POSITION_A), 1_000e18);
        assertEq(fyt.totalSupply(POSITION_B), 1_000e18);

        vm.prank(BURNER1);
        fyt.burn(ALICE, POSITION_A, 1_000e18);
        assertEq(fyt.totalSupply(POSITION_A), 0);
    }

    function test_fyt_totalSupply_zeroBeforeMint() public view {
        assertEq(fyt.totalSupply(POSITION_A), 0);
    }

    // =========================================================================
    // E — FYToken: epochPositionCount tracking
    // =========================================================================

    function test_fyt_epochPositionCount_incrementsOnMint() public {
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 0);

        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);

        _mintFYT(BOB, POSITION_B, EPOCH_ID_0, 2_000e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 2);
    }

    function test_fyt_epochPositionCount_independentPerEpoch() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintFYT(BOB,   POSITION_B, EPOCH_ID_1, 2_000e18);

        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);
        assertEq(fyt.epochPositionCount(EPOCH_ID_1), 1);
    }

    function test_fyt_epochPositionCount_decrementsWhenFullyBurned() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintFYT(BOB,   POSITION_B, EPOCH_ID_0, 2_000e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 2);

        vm.prank(BURNER1);
        fyt.burn(ALICE, POSITION_A, 1_000e18); // full supply for POSITION_A
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);

        vm.prank(BURNER1);
        fyt.burn(BOB, POSITION_B, 1_000e18);
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 0);
    }

    function test_fyt_epochPositionCount_transferDoesNotAffectCount() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1_000e18, "");

        // Transfer doesn't change count.
        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 1);
    }

    // =========================================================================
    // F — FYToken: transfer
    // =========================================================================

    function test_fyt_transfer_holderCanTransfer() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, POSITION_A, 500e18, "");

        assertEq(fyt.balanceOf(ALICE, POSITION_A), 500e18);
        assertEq(fyt.balanceOf(BOB,   POSITION_A), 500e18);
    }

    function test_fyt_transfer_doesNotAffectTotalSupply() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1_000e18, "");

        assertEq(fyt.totalSupply(POSITION_A), 1_000e18);
    }

    // =========================================================================
    // G — VYToken: deployment & roles
    // =========================================================================

    function test_vyt_adminHasAdminRole() public view {
        assertTrue(vyt.hasRole(vyt.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_vyt_minterHasMinterRole() public view {
        assertTrue(vyt.hasRole(vyt.MINTER_ROLE(), MINTER));
    }

    function test_vyt_burnersHaveBurnerRole() public view {
        assertTrue(vyt.hasRole(vyt.BURNER_ROLE(), BURNER1));
        assertTrue(vyt.hasRole(vyt.BURNER_ROLE(), BURNER2));
    }

    function test_vyt_nameAndSymbol() public view {
        assertEq(vyt.name(),   "Paradox Fi Variable Yield Token");
        assertEq(vyt.symbol(), "VYT");
    }

    function test_vyt_fyTokenReference() public view {
        assertEq(address(vyt.fyToken()), address(fyt));
    }

    // =========================================================================
    // H — VYToken: mint
    // =========================================================================

    function test_vyt_mint_minterCanMint() public {
        _mintVYT(ALICE, POSITION_A);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
    }

    function test_vyt_mint_amountIsAlwaysOne() public {
        _mintVYT(ALICE, POSITION_A);
        _mintVYT(BOB,   POSITION_B);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
        assertEq(vyt.balanceOf(BOB,   POSITION_B), 1);
    }

    function test_vyt_mint_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        vyt.mint(ALICE, POSITION_A);
    }

    function test_vyt_mint_differentPositionsDifferentTokenIds() public {
        _mintVYT(ALICE, POSITION_A);
        _mintVYT(ALICE, POSITION_B);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
        assertEq(vyt.balanceOf(ALICE, POSITION_B), 1);
    }

    function test_vyt_mint_totalSupplyIsOne() public {
        _mintVYT(ALICE, POSITION_A);
        assertEq(vyt.totalSupply(POSITION_A), 1);
    }

    // =========================================================================
    // I — VYToken: burn
    // =========================================================================

    function test_vyt_burn_burner1CanBurn() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(BURNER1);
        vyt.burn(ALICE, POSITION_A);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_vyt_burn_burner2CanBurn() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(BURNER2);
        vyt.burn(ALICE, POSITION_A);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_vyt_burn_unauthorizedReverts() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(ALICE);
        vm.expectRevert();
        vyt.burn(ALICE, POSITION_A);
    }

    function test_vyt_burn_minterCannotBurn() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(MINTER);
        vm.expectRevert();
        vyt.burn(ALICE, POSITION_A);
    }

    function test_vyt_burn_totalSupplyGoesToZero() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(BURNER1);
        vyt.burn(ALICE, POSITION_A);
        assertEq(vyt.totalSupply(POSITION_A), 0);
    }

    // =========================================================================
    // J — VYToken: transfer
    // =========================================================================

    function test_vyt_transfer_holderCanTransfer() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
        assertEq(vyt.balanceOf(BOB,   POSITION_A), 1);
    }

    function test_vyt_transfer_doesNotAffectTotalSupply() public {
        _mintVYT(ALICE, POSITION_A);
        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");
        assertEq(vyt.totalSupply(POSITION_A), 1);
    }

    function test_vyt_transfer_newHolderCanBeBurned() public {
        // Alice transfers VYT to Bob (secondary sale).
        _mintVYT(ALICE, POSITION_A);
        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");

        // BURNER2 (MaturityVault) burns from Bob.
        vm.prank(BURNER2);
        vyt.burn(BOB, POSITION_A);
        assertEq(vyt.balanceOf(BOB, POSITION_A), 0);
    }

    // =========================================================================
    // K — Cross-token: FYT and VYT positionId consistency
    // =========================================================================

    function test_cross_samePositionId_bothTokens() public {
        // The hook mints FYT and VYT with the same positionId.
        // Verify they coexist independently keyed by that id.
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintVYT(ALICE, POSITION_A);

        assertEq(fyt.balanceOf(ALICE, POSITION_A), 1_000e18);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
    }

    function test_cross_vydReadPositionFromFYT() public {
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintVYT(ALICE, POSITION_A);

        // VYToken.getPosition delegates to FYToken.
        FYToken.PositionData memory pos = vyt.getPosition(POSITION_A);
        assertEq(pos.epochId,      EPOCH_ID_0);
        assertEq(pos.liquidity,    2_000e18);
        assertEq(pos.halfNotional, 1_000e18);
    }

    function test_cross_transferFYTkeepsVYT() public {
        // FYT transferred to Bob — VYT stays with Alice.
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintVYT(ALICE, POSITION_A);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1_000e18, "");

        assertEq(fyt.balanceOf(BOB,   POSITION_A), 1_000e18);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);   // VYT unchanged
        assertEq(vyt.balanceOf(BOB,   POSITION_A), 0);
    }

    function test_cross_epochPositionCount_matchesVYTPositions() public {
        // FYToken.epochPositionCount replaces the old VYToken.epochSupply.
        // After minting FYT for 3 positions in EPOCH_ID_0, count should be 3.
        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, 2_000e18);
        _mintFYT(BOB,   POSITION_B, EPOCH_ID_0, 2_000e18);
        _mintFYT(ALICE, POSITION_C, EPOCH_ID_0, 2_000e18);

        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 3);
    }

    // =========================================================================
    // L — Fuzz
    // =========================================================================

    /// FYT balanceOf = halfNotional = liquidity / 2.
    function testFuzz_fyt_balanceEqualsHalfNotional(uint128 liquidity) public {
        vm.assume(liquidity >= 2); // halfNotional = liquidity/2 must be > 0

        _mintFYT(ALICE, POSITION_A, EPOCH_ID_0, liquidity);
        assertEq(fyt.balanceOf(ALICE, POSITION_A), liquidity / 2);
    }

    /// epochPositionCount increments once per unique positionId minted into same epoch.
    function testFuzz_fyt_epochPositionCount_correctAfterNMints(uint8 n) public {
        vm.assume(n > 0 && n <= 20);

        for (uint8 i = 1; i <= n; i++) {
            uint256 pid = POSITION_A + i;
            _mintFYT(ALICE, pid, EPOCH_ID_0, 2_000e18);
        }

        assertEq(fyt.epochPositionCount(EPOCH_ID_0), n);
    }

    /// epochPositionCount decrements to zero after burning all positions.
    function testFuzz_fyt_epochPositionCount_zeroAfterBurnAll(uint8 n) public {
        vm.assume(n > 0 && n <= 10);

        uint256[] memory pids = new uint256[](n);
        for (uint8 i = 0; i < n; i++) {
            pids[i] = POSITION_A + i;
            _mintFYT(ALICE, pids[i], EPOCH_ID_0, 2_000e18);
        }

        for (uint8 i = 0; i < n; i++) {
            vm.prank(BURNER1);
            fyt.burn(ALICE, pids[i], 1_000e18);
        }

        assertEq(fyt.epochPositionCount(EPOCH_ID_0), 0);
    }

    /// VYT totalSupply(positionId) is always 0 or 1.
    function testFuzz_vyt_totalSupplyBinary(uint256 positionId) public {
        vm.assume(positionId != 0);

        assertEq(vyt.totalSupply(positionId), 0);

        vm.prank(MINTER);
        vyt.mint(ALICE, positionId);
        assertEq(vyt.totalSupply(positionId), 1);

        vm.prank(BURNER1);
        vyt.burn(ALICE, positionId);
        assertEq(vyt.totalSupply(positionId), 0);
    }
}

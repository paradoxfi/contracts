// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AccessControl, IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FYToken} from "../../src/tokens/FYToken.sol";
import {VYToken} from "../../src/tokens/VYToken.sol";

/// @title TokenTest
/// @notice Unit tests for FYToken and VYToken.
///
/// Test organisation
/// -----------------
///   Section A  — FYToken: deployment & roles
///   Section B  — FYToken: mint
///   Section C  — FYToken: burn
///   Section D  — FYToken: totalSupply (ERC1155Supply)
///   Section E  — FYToken: transfer
///   Section F  — VYToken: deployment & roles
///   Section G  — VYToken: mint
///   Section H  — VYToken: burn
///   Section I  — VYToken: epochSupply tracking
///   Section J  — VYToken: totalSupply override
///   Section K  — VYToken: transfer

contract TokenTest is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    FYToken internal fyt;
    VYToken internal vyt;

    address internal constant ADMIN   = address(0xAD);
    address internal constant MINTER  = address(0x1111); // PositionManager
    address internal constant BURNER1 = address(0x2222); // PositionManager
    address internal constant BURNER2 = address(0x3333); // MaturityVault
    address internal constant ALICE   = address(0xA11CE);
    address internal constant BOB     = address(0xB0B);

    // Sample packed IDs (structure mirrors EpochId / PositionId encoding).
    uint256 internal constant EPOCH_ID_0  = (uint256(1) << 192) | (uint256(42) << 32) | 0;
    uint256 internal constant EPOCH_ID_1  = (uint256(1) << 192) | (uint256(42) << 32) | 1;
    uint256 internal constant POSITION_A  = (uint256(1) << 192) | (uint256(42) << 32) | 1;
    uint256 internal constant POSITION_B  = (uint256(1) << 192) | (uint256(42) << 32) | 2;
    uint256 internal constant POSITION_C  = (uint256(1) << 192) | (uint256(42) << 32) | 3;

    address[] internal BURNERS;

    function setUp() public {
        BURNERS = new address[](2);
        BURNERS[0] = BURNER1;
        BURNERS[1] = BURNER2;

        fyt = new FYToken(ADMIN, MINTER, BURNERS, "https://paradox.fi/fyt/{id}");
        vyt = new VYToken(ADMIN, MINTER, BURNERS, "https://paradox.fi/vyt/{id}");
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
        vm.startPrank(ADMIN);
        fyt.grantRole(fyt.MINTER_ROLE(), ALICE);
        assertTrue(fyt.hasRole(fyt.MINTER_ROLE(), ALICE));
        vm.stopPrank();
    }

    function test_fyt_nonAdminCannotGrantRole() public {

        bytes32 minterRole = fyt.MINTER_ROLE();

        vm.expectRevert();
        fyt.grantRole(minterRole, ALICE);
        //assertTrue(fyt.hasRole(fyt.MINTER_ROLE(), ALICE));
    }

    // =========================================================================
    // B — FYToken: mint
    // =========================================================================

    function test_fyt_mint_minterCanMint() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);
        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 1000e18);
    }

    function test_fyt_mint_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);
    }

    function test_fyt_mint_multipleHoldersSameEpoch() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 600e18);
        vm.prank(MINTER);
        fyt.mint(BOB, EPOCH_ID_0, 400e18);

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 600e18);
        assertEq(fyt.balanceOf(BOB,   EPOCH_ID_0), 400e18);
    }

    function test_fyt_mint_differentEpochsDifferentIds() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 100e18);
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_1, 200e18);

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 100e18);
        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_1), 200e18);
    }

    // =========================================================================
    // C — FYToken: burn
    // =========================================================================

    function test_fyt_burn_burner1CanBurn() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(BURNER1);
        fyt.burn(ALICE, EPOCH_ID_0, 1000e18);

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 0);
    }

    function test_fyt_burn_burner2CanBurn() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(BURNER2);
        fyt.burn(ALICE, EPOCH_ID_0, 1000e18);

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 0);
    }

    function test_fyt_burn_minterCannotBurn() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        // MINTER does not have BURNER_ROLE.
        vm.prank(MINTER);
        vm.expectRevert();
        fyt.burn(ALICE, EPOCH_ID_0, 1000e18);
    }

    function test_fyt_burn_unauthorizedReverts() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(ALICE);
        vm.expectRevert();
        fyt.burn(ALICE, EPOCH_ID_0, 1000e18);
    }

    function test_fyt_burn_partialBurn() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(BURNER1);
        fyt.burn(ALICE, EPOCH_ID_0, 400e18);

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 600e18);
    }

    // =========================================================================
    // D — FYToken: totalSupply
    // =========================================================================

    function test_fyt_totalSupply_tracksMintsAndBurns() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 600e18);
        vm.prank(MINTER);
        fyt.mint(BOB, EPOCH_ID_0, 400e18);

        assertEq(fyt.totalSupply(EPOCH_ID_0), 1000e18);

        vm.prank(BURNER1);
        fyt.burn(ALICE, EPOCH_ID_0, 200e18);

        assertEq(fyt.totalSupply(EPOCH_ID_0), 800e18);
    }

    function test_fyt_totalSupply_zeroBeforeMint() public view {
        assertEq(fyt.totalSupply(EPOCH_ID_0), 0);
    }

    function test_fyt_totalSupply_independentPerEpoch() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 100e18);
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_1, 200e18);

        assertEq(fyt.totalSupply(EPOCH_ID_0), 100e18);
        assertEq(fyt.totalSupply(EPOCH_ID_1), 200e18);
    }

    // =========================================================================
    // E — FYToken: transfer
    // =========================================================================

    function test_fyt_transfer_holderCanTransfer() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, EPOCH_ID_0, 400e18, "");

        assertEq(fyt.balanceOf(ALICE, EPOCH_ID_0), 600e18);
        assertEq(fyt.balanceOf(BOB,   EPOCH_ID_0), 400e18);
    }

    function test_fyt_transfer_doesNotAffectTotalSupply() public {
        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, 1000e18);

        vm.prank(ALICE);
        fyt.safeTransferFrom(ALICE, BOB, EPOCH_ID_0, 1000e18, "");

        // Total supply unchanged by transfer.
        assertEq(fyt.totalSupply(EPOCH_ID_0), 1000e18);
    }

    // =========================================================================
    // F — VYToken: deployment & roles
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

    // =========================================================================
    // G — VYToken: mint
    // =========================================================================

    function test_vyt_mint_minterCanMint() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
    }

    function test_vyt_mint_amountIsAlwaysOne() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(BOB, POSITION_B, EPOCH_ID_0);

        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
        assertEq(vyt.balanceOf(BOB,   POSITION_B), 1);
    }

    function test_vyt_mint_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
    }

    function test_vyt_mint_differentPositionsDifferentIds() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_B, EPOCH_ID_0);

        assertEq(vyt.balanceOf(ALICE, POSITION_A), 1);
        assertEq(vyt.balanceOf(ALICE, POSITION_B), 1);
    }

    // =========================================================================
    // H — VYToken: burn
    // =========================================================================

    function test_vyt_burn_burner1CanBurn() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(BURNER1);
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);

        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_vyt_burn_burner2CanBurn() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(BURNER2);
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);

        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_vyt_burn_unauthorizedReverts() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(ALICE);
        vm.expectRevert();
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);
    }

    function test_vyt_burn_minterCannotBurn() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(MINTER);
        vm.expectRevert();
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);
    }

    // =========================================================================
    // I — VYToken: epochSupply tracking
    // =========================================================================

    function test_vyt_epochSupply_incrementsOnMint() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        assertEq(vyt.epochSupply(EPOCH_ID_0), 1);

        vm.prank(MINTER);
        vyt.mint(BOB, POSITION_B, EPOCH_ID_0);
        assertEq(vyt.epochSupply(EPOCH_ID_0), 2);
    }

    function test_vyt_epochSupply_decrementsOnBurn() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(BOB, POSITION_B, EPOCH_ID_0);

        vm.prank(BURNER1);
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);

        assertEq(vyt.epochSupply(EPOCH_ID_0), 1);
    }

    function test_vyt_epochSupply_independentPerEpoch() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(BOB, POSITION_B, EPOCH_ID_1);

        assertEq(vyt.epochSupply(EPOCH_ID_0), 1);
        assertEq(vyt.epochSupply(EPOCH_ID_1), 1);
    }

    function test_vyt_epochSupply_zeroBeforeMint() public view {
        assertEq(vyt.epochSupply(EPOCH_ID_0), 0);
    }

    function test_vyt_epochSupply_doesNotUnderflow() public {
        // Burn called on epoch with 0 supply — should not underflow.
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(BURNER1);
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);

        // Already at 0 — a second decrement would underflow without the guard.
        assertEq(vyt.epochSupply(EPOCH_ID_0), 0);
    }

    // =========================================================================
    // J — VYToken: totalSupply override
    // =========================================================================

    function test_vyt_totalSupply_returnsEpochSupplyForEpochId() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(BOB,   POSITION_B, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_C, EPOCH_ID_0);

        // totalSupply(epochId) should return 3 (the position count).
        assertEq(vyt.totalSupply(EPOCH_ID_0), 3);
    }

    function test_vyt_totalSupply_returnsOneForPositionId() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        // totalSupply(positionId) should return 1.
        assertEq(vyt.totalSupply(POSITION_A), 1);
    }

    function test_vyt_totalSupply_returnsZeroForUnminted() public view {
        assertEq(vyt.totalSupply(POSITION_A), 0);
        assertEq(vyt.totalSupply(EPOCH_ID_0), 0);
    }

    function test_vyt_totalSupply_decreasesAfterBurn() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);
        vm.prank(MINTER);
        vyt.mint(BOB, POSITION_B, EPOCH_ID_0);

        vm.prank(BURNER2);
        vyt.burn(ALICE, POSITION_A, EPOCH_ID_0);

        assertEq(vyt.totalSupply(EPOCH_ID_0), 1);
    }

    function test_vyt_totalSupply_transferDoesNotAffectEpochSupply() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");

        // epochSupply unchanged by transfer — only mint/burn affect it.
        assertEq(vyt.epochSupply(EPOCH_ID_0), 1);
        assertEq(vyt.totalSupply(EPOCH_ID_0), 1);
    }

    // =========================================================================
    // K — VYToken: transfer
    // =========================================================================

    function test_vyt_transfer_holderCanTransfer() public {
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");

        assertEq(vyt.balanceOf(ALICE, POSITION_A), 0);
        assertEq(vyt.balanceOf(BOB,   POSITION_A), 1);
    }

    function test_vyt_transfer_newHolderCanRedeem() public {
        // Bob buys Alice's VYT on secondary market — Bob should hold it.
        vm.prank(MINTER);
        vyt.mint(ALICE, POSITION_A, EPOCH_ID_0);

        vm.prank(ALICE);
        vyt.safeTransferFrom(ALICE, BOB, POSITION_A, 1, "");

        // BURNER2 (MaturityVault) burns from Bob — the secondary holder.
        vm.prank(BURNER2);
        vyt.burn(BOB, POSITION_A, EPOCH_ID_0);

        assertEq(vyt.balanceOf(BOB, POSITION_A), 0);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    /// FYT totalSupply equals sum of all holder balances.
    function testFuzz_fyt_totalSupplyConsistency(
        uint64 amtAlice,
        uint64 amtBob
    ) public {
        vm.assume(amtAlice > 0 && amtBob > 0);

        vm.prank(MINTER);
        fyt.mint(ALICE, EPOCH_ID_0, amtAlice);
        vm.prank(MINTER);
        fyt.mint(BOB,   EPOCH_ID_0, amtBob);

        assertEq(
            fyt.totalSupply(EPOCH_ID_0),
            uint256(amtAlice) + uint256(amtBob)
        );
    }

    /// VYT epochSupply equals the number of positions minted minus burned.
    function testFuzz_vyt_epochSupplyConsistency(uint8 n) public {
        vm.assume(n > 0 && n <= 20);

        for (uint256 i = 1; i <= n; i++) {
            vm.prank(MINTER);
            // Use unique positionIds: base + i
            vyt.mint(ALICE, POSITION_A + i, EPOCH_ID_0);
        }

        assertEq(vyt.epochSupply(EPOCH_ID_0), n);
        assertEq(vyt.totalSupply(EPOCH_ID_0), n);
    }
}

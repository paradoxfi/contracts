// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AuthorizedCaller} from "../../src/libraries/AuthorizedCaller.sol";
import {
    MaturityVault,
    IFYToken,
    IVYToken
} from "../../src/core/MaturityVault.sol";
import {IFYToken} from "../../src/interfaces/IFYToken.sol";
import {IVYToken} from "../../src/interfaces/IVYToken.sol";

/// @title MaturityVaultTest
/// @notice Unit and fuzz tests for MaturityVault.
///
/// Test organisation
/// -----------------
///   Section A  — deployment & governance
///   Section B  — receiveSettlement
///   Section C  — redeemFYT: happy path
///   Section D  — redeemFYT: revert cases
///   Section E  — redeemVYT: happy path
///   Section F  — redeemVYT: revert cases
///   Section G  — pro-rata correctness (multi-holder)
///   Section H  — preview functions
///   Section I  — fuzz

// =============================================================================
// Mocks
// =============================================================================

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal FYToken mock: tracks balances and totalSupply per tokenId.
contract MockFYToken is IFYToken {
    mapping(uint256 => mapping(address => uint256)) public balances;
    mapping(uint256 => uint256) public supplies;

    function mint(address to, uint256 id, uint256 amount) external {
        balances[id][to] += amount;
        supplies[id] += amount;
    }

    function balanceOf(
        address account,
        uint256 id
    ) external view override returns (uint256) {
        return balances[id][account];
    }

    function totalSupply(uint256 id) external view override returns (uint256) {
        return supplies[id];
    }

    function burn(
        address account,
        uint256 id,
        uint256 amount
    ) external override {
        require(balances[id][account] >= amount, "insufficient balance");
        balances[id][account] -= amount;
        supplies[id] -= amount;
    }
}

/// @dev Minimal VYToken mock: each positionId has at most 1 token.
contract MockVYToken is IVYToken {
    mapping(uint256 => address) public holders;
    mapping(uint256 => uint256) public epochSupply;

    function mint(address to, uint256 positionId, uint256 epochId) external {
        holders[positionId] = to;
        epochSupply[epochId]++;
    }

    function balanceOf(
        address account,
        uint256 id
    ) external view override returns (uint256) {
        return holders[id] == account ? 1 : 0;
    }

    function totalSupply(uint256 epochId) external view override returns (uint256) {
        return epochSupply[epochId];
    }

    function burn(
        address account,
        uint256 positionId,
        uint256 amount
    ) external override {
        require(holders[positionId] == account, "not holder");
        require(amount == 1, "VYT amount must be 1");
        holders[positionId] = address(0);
    }
}

// =============================================================================
// Test contract
// =============================================================================

contract MaturityVaultTest is Test {
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    MaturityVault internal mv;
    MockERC20 internal token;
    MockFYToken internal fyToken;
    MockVYToken internal vyToken;

    address internal constant OWNER = address(0xA110CE);
    address internal constant ROUTER = address(0xB0117E); // YieldRouter
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA501);

    // Canonical IDs.
    uint256 internal constant EPOCH_ID =
        (uint256(1) << 192) | (uint256(7) << 32);
    uint256 internal constant POSITION_A =
        (uint256(1) << 192) | (uint256(1) << 32) | 1;
    uint256 internal constant POSITION_B =
        (uint256(1) << 192) | (uint256(1) << 32) | 2;

    function setUp() public {
        token = new MockERC20();
        fyToken = new MockFYToken();
        vyToken = new MockVYToken();

        mv = new MaturityVault(OWNER, ROUTER, fyToken, vyToken);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Push a settlement record and fund the vault.
    function _settle(uint128 fytTotal, uint128 vytTotal) internal {
        token.mint(address(mv), uint256(fytTotal) + uint256(vytTotal));
        vm.prank(ROUTER);
        mv.receiveSettlement(EPOCH_ID, address(token), fytTotal, vytTotal);
    }

    /// Mint `amount` FYT to `holder` for EPOCH_ID.
    function _mintFYT(address holder, uint256 amount) internal {
        fyToken.mint(holder, EPOCH_ID, amount);
    }

    /// Mint one VYT to `holder` for `positionId`.
    function _mintVYT(address holder, uint256 positionId) internal {
        vyToken.mint(holder, positionId, EPOCH_ID);
    }

    // =========================================================================
    // A — deployment & governance
    // =========================================================================

    function test_deploy_ownerSet() public view {
        assertEq(mv.owner(), OWNER);
    }

    function test_deploy_authorizedCallerSet() public view {
        assertEq(mv.authorizedCaller(), ROUTER);
    }

    function test_deploy_zeroOwnerReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                address(0)
            )
        );
        new MaturityVault(address(0), ROUTER, fyToken, vyToken);
    }

    function test_deploy_zeroFYTokenReverts() public {
        vm.expectRevert(MaturityVault.ZeroAddress.selector);
        new MaturityVault(OWNER, ROUTER, IFYToken(address(0)), vyToken);
    }

    function test_deploy_zeroVYTokenReverts() public {
        vm.expectRevert(MaturityVault.ZeroAddress.selector);
        new MaturityVault(OWNER, ROUTER, fyToken, IVYToken(address(0)));
    }

    // =========================================================================
    // B — receiveSettlement
    // =========================================================================

    function test_receiveSettlement_storesRecord() public {
        _mintFYT(ALICE, 100e18);
        _mintVYT(BOB, POSITION_A);

        _settle(90e18, 10e18);

        (
            address tok,
            uint128 fytTotal,
            uint128 vytTotal,
            uint128 fytSupply,
            uint128 vytSupply,
            bool finalized
        ) = mv.settlements(EPOCH_ID);

        assertEq(tok, address(token));
        assertEq(fytTotal, 90e18);
        assertEq(vytTotal, 10e18);
        assertEq(fytSupply, 100e18);
        assertEq(vytSupply, 1);
        assertTrue(finalized);
    }

    function test_receiveSettlement_snapshotsTakenAtSettleTime() public {
        // Mint before settlement.
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        // Mint after — should NOT change the snapshot.
        _mintFYT(BOB, 50e18);

        (, , , uint128 fytSupply, , ) = mv.settlements(EPOCH_ID);
        assertEq(
            fytSupply,
            100e18,
            "snapshot must not include post-settlement mints"
        );
    }

    function test_receiveSettlement_duplicateReverts() public {
        _settle(90e18, 10e18);

        token.mint(address(mv), 100e18);
        vm.prank(ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.EpochAlreadyFinalized.selector,
                EPOCH_ID
            )
        );
        mv.receiveSettlement(EPOCH_ID, address(token), 90e18, 10e18);
    }

    function test_receiveSettlement_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(AuthorizedCaller.NotAuthorized.selector);
        mv.receiveSettlement(EPOCH_ID, address(token), 90e18, 10e18);
    }

    function test_receiveSettlement_emitsEvent() public {
        _mintFYT(ALICE, 100e18);

        token.mint(address(mv), 90e18);
        vm.prank(ROUTER);
        vm.expectEmit(true, false, false, true);
        emit MaturityVault.SettlementReceived(
            EPOCH_ID,
            address(token),
            90e18,
            0,
            100e18,
            0
        );
        mv.receiveSettlement(EPOCH_ID, address(token), 90e18, 0);
    }

    // =========================================================================
    // C — redeemFYT: happy path
    // =========================================================================

    function test_redeemFYT_singleHolder_fullSupply() public {
        // Alice holds 100% of FYT supply.
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        uint256 balBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        // payout = 100e18 × 90e18 / 100e18 = 90e18
        assertEq(token.balanceOf(ALICE) - balBefore, 90e18);
    }

    function test_redeemFYT_burnsFYTBalance() public {
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        assertEq(fyToken.balanceOf(ALICE, EPOCH_ID), 0);
    }

    function test_redeemFYT_setsClaimed() public {
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        assertTrue(mv.fytClaimed(EPOCH_ID, ALICE));
    }

    function test_redeemFYT_emitsEvent() public {
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit MaturityVault.FYTRedeemed(EPOCH_ID, ALICE, 100e18, 90e18);
        mv.redeemFYT(EPOCH_ID);
    }

    // =========================================================================
    // D — redeemFYT: revert cases
    // =========================================================================

    function test_redeemFYT_notFinalizedReverts() public {
        _mintFYT(ALICE, 100e18);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.EpochNotFinalized.selector,
                EPOCH_ID
            )
        );
        mv.redeemFYT(EPOCH_ID);
    }

    function test_redeemFYT_doubleClaimReverts() public {
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.FYTAlreadyClaimed.selector,
                EPOCH_ID,
                ALICE
            )
        );
        mv.redeemFYT(EPOCH_ID);
    }

    function test_redeemFYT_noBalanceReverts() public {
        _settle(90e18, 0);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.NoFYTBalance.selector,
                EPOCH_ID,
                ALICE
            )
        );
        mv.redeemFYT(EPOCH_ID);
    }

    // =========================================================================
    // E — redeemVYT: happy path
    // =========================================================================

    function test_redeemVYT_singlePosition() public {
        _mintVYT(ALICE, POSITION_A);
        _settle(0, 50e18);

        uint256 balBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);

        // payout = 50e18 / 1 = 50e18
        assertEq(token.balanceOf(ALICE) - balBefore, 50e18);
    }

    function test_redeemVYT_burnsVYTToken() public {
        _mintVYT(ALICE, POSITION_A);
        _settle(0, 50e18);

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);

        assertEq(vyToken.balanceOf(ALICE, POSITION_A), 0);
    }

    function test_redeemVYT_setsClaimed() public {
        _mintVYT(ALICE, POSITION_A);
        _settle(0, 50e18);

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);

        assertTrue(mv.vytClaimed(POSITION_A));
    }

    function test_redeemVYT_zeroPayoutZoneBC_stillBurns() public {
        // Zone B/C: vytTotal = 0.
        _mintVYT(ALICE, POSITION_A);
        _settle(100e18, 0); // no variable tranche

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);

        assertEq(vyToken.balanceOf(ALICE, POSITION_A), 0);
        assertTrue(mv.vytClaimed(POSITION_A));
    }

    function test_redeemVYT_emitsEvent() public {
        _mintVYT(ALICE, POSITION_A);
        _settle(0, 50e18);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit MaturityVault.VYTRedeemed(POSITION_A, ALICE, 50e18);
        mv.redeemVYT(EPOCH_ID, POSITION_A);
    }

    // =========================================================================
    // F — redeemVYT: revert cases
    // =========================================================================

    function test_redeemVYT_notFinalizedReverts() public {
        _mintVYT(ALICE, POSITION_A);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.EpochNotFinalized.selector,
                EPOCH_ID
            )
        );
        mv.redeemVYT(EPOCH_ID, POSITION_A);
    }

    function test_redeemVYT_doubleClaimReverts() public {
        _mintVYT(ALICE, POSITION_A);
        _settle(0, 50e18);

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.VYTAlreadyClaimed.selector,
                POSITION_A
            )
        );
        mv.redeemVYT(EPOCH_ID, POSITION_A);
    }

    function test_redeemVYT_noBalanceReverts() public {
        _mintVYT(BOB, POSITION_A); // Bob holds it, Alice doesn't
        _settle(0, 50e18);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaturityVault.NoVYTBalance.selector,
                POSITION_A,
                ALICE
            )
        );
        mv.redeemVYT(EPOCH_ID, POSITION_A);
    }

    // =========================================================================
    // G — pro-rata correctness (multi-holder)
    // =========================================================================

    function test_proRata_FYT_twoHolders() public {
        // Alice: 300, Bob: 100 → Alice gets 75%, Bob gets 25%.
        _mintFYT(ALICE, 300e18);
        _mintFYT(BOB, 100e18);
        _settle(80e18, 0); // fytTotal = 80

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);
        vm.prank(BOB);
        mv.redeemFYT(EPOCH_ID);

        // Alice: 300/400 × 80 = 60. Bob: 100/400 × 80 = 20.
        assertEq(token.balanceOf(ALICE), 60e18);
        assertEq(token.balanceOf(BOB), 20e18);
    }

    function test_proRata_FYT_totalPayoutLeqFytTotal() public {
        // Rounding down means total paid out ≤ fytTotal (dust stays in vault).
        _mintFYT(ALICE, 1);
        _mintFYT(BOB, 1);
        _mintFYT(CAROL, 1);
        _settle(10e18, 0); // 10e18 / 3 = 3.33..e18 × 3 holders

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);
        vm.prank(BOB);
        mv.redeemFYT(EPOCH_ID);
        vm.prank(CAROL);
        mv.redeemFYT(EPOCH_ID);

        uint256 totalPaid = token.balanceOf(ALICE) +
            token.balanceOf(BOB) +
            token.balanceOf(CAROL);

        assertLe(totalPaid, 10e18, "total payout must not exceed fytTotal");
    }

    function test_proRata_VYT_twoPositions_equalSplit() public {
        _mintVYT(ALICE, POSITION_A);
        _mintVYT(BOB, POSITION_B);
        _settle(0, 60e18); // vytTotal = 60, supply = 2

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);
        vm.prank(BOB);
        mv.redeemVYT(EPOCH_ID, POSITION_B);

        // Each gets 60 / 2 = 30.
        assertEq(token.balanceOf(ALICE), 30e18);
        assertEq(token.balanceOf(BOB), 30e18);
    }

    function test_proRata_VYT_totalPayoutLeqVytTotal() public {
        // 3 positions, 10e18 variable. 10e18 / 3 rounds down → dust remains.
        uint256 posC = POSITION_B + 1;
        _mintVYT(ALICE, POSITION_A);
        _mintVYT(BOB, POSITION_B);
        _mintVYT(CAROL, posC);
        _settle(0, 10e18);

        vm.prank(ALICE);
        mv.redeemVYT(EPOCH_ID, POSITION_A);
        vm.prank(BOB);
        mv.redeemVYT(EPOCH_ID, POSITION_B);
        vm.prank(CAROL);
        mv.redeemVYT(EPOCH_ID, posC);

        uint256 totalPaid = token.balanceOf(ALICE) +
            token.balanceOf(BOB) +
            token.balanceOf(CAROL);

        assertLe(totalPaid, 10e18, "total VYT payout must not exceed vytTotal");
    }

    function test_laterBuyer_doesNotDiluteEarlyHolder() public {
        // Alice mints FYT before settlement. Bob buys after — snapshot already frozen.
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        // Bob acquires FYT after settlement (e.g. secondary market).
        // The mock doesn't enforce transfer mechanics, but the supply snapshot is frozen.
        // Alice should still get her full 90e18 pro-rata.
        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        assertEq(token.balanceOf(ALICE), 90e18);
    }

    // =========================================================================
    // H — preview functions
    // =========================================================================

    function test_previewFYTPayout_beforeSettle_returnsZero() public view {
        assertEq(mv.previewFYTPayout(EPOCH_ID, ALICE), 0);
    }

    function test_previewFYTPayout_matchesActual() public {
        _mintFYT(ALICE, 300e18);
        _mintFYT(BOB, 100e18);
        _settle(80e18, 0);

        uint128 preview = mv.previewFYTPayout(EPOCH_ID, ALICE);
        assertEq(preview, 60e18); // 300/400 × 80
    }

    function test_previewFYTPayout_zeroAfterClaim() public {
        _mintFYT(ALICE, 100e18);
        _settle(90e18, 0);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        assertEq(mv.previewFYTPayout(EPOCH_ID, ALICE), 0);
    }

    function test_previewVYTPayout_matchesActual() public {
        _mintVYT(ALICE, POSITION_A);
        _mintVYT(BOB, POSITION_B);
        _settle(0, 60e18);

        assertEq(mv.previewVYTPayout(EPOCH_ID, POSITION_A), 30e18);
    }

    // =========================================================================
    // I — fuzz
    // =========================================================================

    /// Pro-rata invariant: single holder always gets fytTotal (no rounding loss).
    function testFuzz_redeemFYT_singleHolder_getsAll(
        uint64 fytAmount,
        uint64 fytTotal
    ) public {
        vm.assume(fytAmount > 0);
        vm.assume(fytTotal > 0);

        _mintFYT(ALICE, fytAmount);
        token.mint(address(mv), fytTotal);
        vm.prank(ROUTER);
        mv.receiveSettlement(EPOCH_ID, address(token), uint128(fytTotal), 0);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);

        // Single holder with 100% of supply: payout = fytAmount × fytTotal / fytAmount = fytTotal.
        assertEq(token.balanceOf(ALICE), fytTotal);
    }

    /// FYT payout is always ≤ fytTotal regardless of balances and supply.
    function testFuzz_redeemFYT_payoutBounded(
        uint64 aliceBal,
        uint64 bobBal,
        uint64 fytTotal
    ) public {
        vm.assume(aliceBal > 0 && bobBal > 0);
        vm.assume(uint256(aliceBal) + uint256(bobBal) <= type(uint128).max);
        vm.assume(fytTotal > 0);

        _mintFYT(ALICE, aliceBal);
        _mintFYT(BOB, bobBal);

        token.mint(address(mv), fytTotal);
        vm.prank(ROUTER);
        mv.receiveSettlement(EPOCH_ID, address(token), uint128(fytTotal), 0);

        uint256 alicePre = token.balanceOf(ALICE);
        uint256 bobPre = token.balanceOf(BOB);

        vm.prank(ALICE);
        mv.redeemFYT(EPOCH_ID);
        vm.prank(BOB);
        mv.redeemFYT(EPOCH_ID);

        uint256 totalPaid = (token.balanceOf(ALICE) - alicePre) +
            (token.balanceOf(BOB) - bobPre);

        assertLe(totalPaid, fytTotal, "total payout must not exceed fytTotal");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {HarborTideDistributor_v1} from "@tide/HarborTideDistributor_v1.sol";
import {IHarborTideDistributor} from "@tide/interfaces/IHarborTideDistributor.sol";
import {IHarborTideDistributorConfig} from "@tide/interfaces/IHarborTideDistributorConfig.sol";
import {IHarborTideDistributorErrors} from "@tide/interfaces/IHarborTideDistributorErrors.sol";

import {MockERC20} from "@tide-test-mocks/MockERC20.sol";
import {MockVotingEscrow} from "@tide-test-mocks/MockVotingEscrow.sol";

contract HarborTideDistributorV1Test is Test {
    HarborTideDistributor_v1 internal dist;
    MockERC20 internal tide;
    MockERC20 internal bao;
    MockVotingEscrow internal ve;

    address internal multisig = address(0xB0B0);
    address internal configOps = address(0xC04F16);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal startDate;
    uint256 internal endDate;
    uint256 internal constant SNAPSHOT_BLOCK = 100;

    uint256 internal constant FUNDING = 280_000_000e18;
    uint256 internal constant VE_TIDE = 1_000_000e18;
    uint256 internal constant STD_TIDE = 500_000e18;

    function setUp() public {
        vm.roll(SNAPSHOT_BLOCK);

        tide = new MockERC20("Tide", "TIDE");
        bao = new MockERC20("Bao", "BAO");
        ve = new MockVotingEscrow();

        startDate = block.timestamp + 1 days;
        endDate = startDate + 7 days;

        dist = new HarborTideDistributor_v1(
            address(tide),
            address(bao),
            address(ve),
            startDate,
            endDate,
            SNAPSHOT_BLOCK,
            multisig,
            _leaf(alice, VE_TIDE),
            _leaf(alice, STD_TIDE)
        );

        tide.mint(address(dist), FUNDING);

        // default eligible veBAO position for alice
        ve.setSnapshot(alice, 10_000_000e18);
        ve.setLocked(alice, int128(uint128(12_000_000e18)), endDate + 30 days);

        uint256 configRole = dist.CONFIG_ROLE();
        vm.prank(multisig);
        dist.grantRoles(configOps, configRole);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _enterWindow() internal {
        vm.warp(startDate + 1);
    }

    function _fundBao(address user, uint256 amount) internal {
        bao.mint(user, amount);
        vm.prank(user);
        bao.approve(address(dist), amount);
    }

    /*//////////////////////////////////////////////////////////////
                          PATH 1 — SWAP
    //////////////////////////////////////////////////////////////*/

    function testConvertBaoHappyPath() public {
        uint256 baoIn = 1_000_000e18;
        uint256 expectedTide = dist.baoToTide(baoIn);
        _fundBao(alice, baoIn);
        _enterWindow();

        vm.prank(alice);
        dist.convertBao(baoIn);

        assertEq(tide.balanceOf(alice), expectedTide);
        assertEq(bao.balanceOf(multisig), baoIn, "BAO forwarded to multisig in same tx");
        assertEq(bao.balanceOf(address(dist)), 0, "no BAO held");
        assertEq(dist.totalBaoConverted(), baoIn);
        assertEq(dist.totalTideSwapAndVe(), expectedTide);
        assertEq(dist.baoConverted(alice), baoIn);
    }

    function testConvertBaoRevertsBelowMinSwap() public {
        uint256 minBao = dist.tideToBao(dist.MIN_TIDE_OUT());
        _fundBao(alice, minBao);
        _enterWindow();

        // one wei below the minimum BAO input yields < MIN_TIDE_OUT
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.BelowMinSwap.selector);
        dist.convertBao(minBao - 1);

        // exactly the minimum succeeds
        vm.prank(alice);
        dist.convertBao(minBao);
        assertGe(tide.balanceOf(alice), dist.MIN_TIDE_OUT());
    }

    function testConvertBaoRevertsWhenBaoCapExceeded() public {
        // fund enough TIDE is irrelevant; cap is on BAO input. Use a fresh distributor with tiny caps? No —
        // MAX_BAO is constant. Exceed by requesting > MAX_BAO in a single call.
        uint256 baoIn = dist.MAX_BAO() + 1;
        _fundBao(alice, baoIn);
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.BaoCapExceeded.selector);
        dist.convertBao(baoIn);
    }

    function testConvertBaoRevertsOutsideWindow() public {
        uint256 baoIn = 1_000_000e18;
        _fundBao(alice, baoIn);

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimNotStarted.selector);
        dist.convertBao(baoIn);

        vm.warp(endDate);
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimEnded.selector);
        dist.convertBao(baoIn);
    }

    /*//////////////////////////////////////////////////////////////
                          PATH 2 — veBAO
    //////////////////////////////////////////////////////////////*/

    function testClaimVeBaoHappyPath() public {
        _enterWindow();

        vm.prank(alice);
        dist.claimVeBao(VE_TIDE, _emptyProof());

        assertEq(tide.balanceOf(alice), VE_TIDE);
        assertTrue(dist.hasClaimedVeBao(alice));
        assertEq(dist.totalTideSwapAndVe(), VE_TIDE);
    }

    function testGetVeClaimStatusMatchesEligibility() public {
        _enterWindow();

        IHarborTideDistributor.VeClaimStatus memory s = dist.getVeClaimStatus(alice, VE_TIDE);
        assertTrue(s.canClaimNow);
        assertEq(s.veEnd, endDate + 30 days);
        assertEq(s.lockedAmount, 12_000_000e18);
        assertEq(s.snapshotBaoEquivalent, 10_000_000e18);
        assertEq(s.snapshotRequired, dist.tideToBao(VE_TIDE));
        assertEq(s.minUnlockTime, endDate + 1);
        assertFalse(s.alreadyClaimed);
        assertTrue(s.poolCapAvailable);

        vm.prank(alice);
        dist.claimVeBao(VE_TIDE, _emptyProof());

        s = dist.getVeClaimStatus(alice, VE_TIDE);
        assertFalse(s.canClaimNow);
        assertTrue(s.alreadyClaimed);
    }

    function testClaimVeBaoRevertsWhenLockEndTooEarly() public {
        ve.setLocked(alice, int128(uint128(12_000_000e18)), endDate); // veEnd == endDate, not > endDate
        _enterWindow();

        IHarborTideDistributor.VeClaimStatus memory s = dist.getVeClaimStatus(alice, VE_TIDE);
        assertFalse(s.canClaimNow);

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.LockEndTooEarly.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoRevertsWhenLockedBelowSnapshot() public {
        ve.setLocked(alice, int128(uint128(9_999_999e18)), endDate + 30 days); // below snapshot (10m)
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.LockBelowSnapshot.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoSucceedsWhenLockedAboveSnapshot() public {
        // partial withdraw scenario: locked dropped but still >= snapshot -> allowed by design
        ve.setLocked(alice, int128(uint128(10_000_000e18)), endDate + 30 days); // exactly snapshot
        _enterWindow();

        vm.prank(alice);
        dist.claimVeBao(VE_TIDE, _emptyProof());
        assertEq(tide.balanceOf(alice), VE_TIDE);
    }

    function testClaimVeBaoRevertsWhenSnapshotInsufficient() public {
        ve.setSnapshot(alice, dist.tideToBao(VE_TIDE) - 1); // below required
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.InsufficientSnapshotBalance.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoRevertsBeforeSnapshotBlock() public {
        vm.roll(SNAPSHOT_BLOCK - 1);
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.SnapshotNotReached.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoRevertsOutsideWindow() public {
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimNotStarted.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());

        vm.warp(endDate);
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimEnded.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoDoubleClaimReverts() public {
        _enterWindow();
        vm.prank(alice);
        dist.claimVeBao(VE_TIDE, _emptyProof());

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.AlreadyClaimed.selector);
        dist.claimVeBao(VE_TIDE, _emptyProof());
    }

    function testClaimVeBaoInvalidProofReverts() public {
        _enterWindow();
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("nope");

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.InvalidProof.selector);
        dist.claimVeBao(VE_TIDE, badProof);
    }

    function testClaimVeBaoProofAmountBinding() public {
        _enterWindow();
        // valid proof exists for (alice, VE_TIDE); claiming a different amount must fail
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.InvalidProof.selector);
        dist.claimVeBao(VE_TIDE + 1, _emptyProof());
    }

    function testClaimVeBaoRevertsWhenPoolCapExceeded() public {
        uint256 huge = dist.MAX_TIDE_SWAP_AND_VE() + 1;
        vm.prank(multisig);
        dist.setVeBaoMerkleRoot(_leaf(alice, huge));
        ve.setSnapshot(alice, 2_000_000_000e18);
        ve.setLocked(alice, int128(uint128(2_000_000_000e18)), endDate + 30 days);
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.TideSwapVeCapExceeded.selector);
        dist.claimVeBao(huge, _emptyProof());
    }

    /*//////////////////////////////////////////////////////////////
                          PATH 3 — STANDARD
    //////////////////////////////////////////////////////////////*/

    function testClaimStandardHappyPath() public {
        _enterWindow();
        vm.prank(alice);
        dist.claimStandard(STD_TIDE, _emptyProof());

        assertEq(tide.balanceOf(alice), STD_TIDE);
        assertTrue(dist.hasClaimedStandard(alice));
        assertEq(dist.totalTideStandard(), STD_TIDE);
    }

    function testClaimStandardProofAmountBinding() public {
        _enterWindow();
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.InvalidProof.selector);
        dist.claimStandard(STD_TIDE + 1, _emptyProof());
    }

    function testClaimStandardRevertsWhenCapExceeded() public {
        uint256 huge = dist.MAX_TIDE_STANDARD() + 1;
        vm.prank(multisig);
        dist.setStandardMerkleRoot(_leaf(alice, huge));
        _enterWindow();

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.TideStandardCapExceeded.selector);
        dist.claimStandard(huge, _emptyProof());
    }

    function testClaimStandardRevertsAfterEnd() public {
        vm.warp(endDate);
        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimEnded.selector);
        dist.claimStandard(STD_TIDE, _emptyProof());
    }

    function testClaimStandardDoubleClaimReverts() public {
        _enterWindow();
        vm.prank(alice);
        dist.claimStandard(STD_TIDE, _emptyProof());

        vm.prank(alice);
        vm.expectRevert(IHarborTideDistributorErrors.AlreadyClaimed.selector);
        dist.claimStandard(STD_TIDE, _emptyProof());
    }

    /*//////////////////////////////////////////////////////////////
                          SHARED / CAPS / AUTH
    //////////////////////////////////////////////////////////////*/

    function testSharedPoolHitExactlyByPath1AndPath2() public {
        uint256 path1Tide = dist.baoToTide(1_000_000e18);
        uint256 remaining = dist.MAX_TIDE_SWAP_AND_VE() - path1Tide;

        vm.prank(multisig);
        dist.setVeBaoMerkleRoot(_leaf(alice, remaining));
        ve.setSnapshot(alice, 2_000_000_000e18);
        ve.setLocked(alice, int128(uint128(2_000_000_000e18)), endDate + 30 days);

        _fundBao(alice, 1_000_000e18);
        _enterWindow();

        vm.startPrank(alice);
        dist.convertBao(1_000_000e18);
        dist.claimVeBao(remaining, _emptyProof());
        vm.stopPrank();

        assertEq(dist.totalTideSwapAndVe(), dist.MAX_TIDE_SWAP_AND_VE(), "pool filled exactly");

        // pool is now full: a further min-size swap reverts on the shared cap
        _fundBao(bob, 100_000_000e18);
        vm.prank(bob);
        vm.expectRevert(IHarborTideDistributorErrors.TideSwapVeCapExceeded.selector);
        dist.convertBao(100_000_000e18);
    }

    function testAllThreePathsSameAddress() public {
        uint256 baoIn = 1_000_000e18;
        uint256 expectedSwap = dist.baoToTide(baoIn);
        _fundBao(alice, baoIn);
        _enterWindow();

        vm.startPrank(alice);
        dist.convertBao(baoIn);
        dist.claimVeBao(VE_TIDE, _emptyProof());
        dist.claimStandard(STD_TIDE, _emptyProof());
        vm.stopPrank();

        assertEq(tide.balanceOf(alice), expectedSwap + VE_TIDE + STD_TIDE);
        assertEq(dist.totalTideSwapAndVe(), expectedSwap + VE_TIDE);
        assertEq(dist.totalTideStandard(), STD_TIDE);
    }

    function testConfigRoleCanSetRootsBeforeStart() public {
        bytes32 newRoot = keccak256("new ve root");
        vm.prank(configOps);
        dist.setVeBaoMerkleRoot(newRoot);
        assertEq(dist.veBaoMerkleRoot(), newRoot);
    }

    function testSetRootRevertsAfterStart() public {
        _enterWindow();
        vm.prank(multisig);
        vm.expectRevert(IHarborTideDistributorErrors.ConfigLocked.selector);
        dist.setVeBaoMerkleRoot(keccak256("late"));
    }

    function testSetMultisigBeforeStart() public {
        vm.prank(multisig);
        dist.setMultisig(bob);
        assertEq(dist.multisig(), bob);
    }

    function testSetMultisigRevertsAfterStart() public {
        _enterWindow();
        vm.prank(multisig);
        vm.expectRevert(IHarborTideDistributorErrors.ConfigLocked.selector);
        dist.setMultisig(bob);
    }

    function testConfigRoleCannotSetMultisig() public {
        vm.prank(configOps);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        dist.setMultisig(bob);
    }

    function testConfigRoleCannotSweep() public {
        vm.warp(endDate + 1);
        vm.prank(configOps);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        dist.sweep();
    }

    /*//////////////////////////////////////////////////////////////
                          SWEEP / RECOVERY
    //////////////////////////////////////////////////////////////*/

    function testSweepAfterEnd() public {
        vm.warp(endDate + 1);
        uint256 before = tide.balanceOf(multisig);
        vm.prank(multisig);
        dist.sweep();
        assertEq(tide.balanceOf(multisig), before + FUNDING);
        assertEq(tide.balanceOf(address(dist)), 0);
    }

    function testSweepRevertsBeforeEnd() public {
        vm.prank(multisig);
        vm.expectRevert(IHarborTideDistributorErrors.ClaimNotOver.selector);
        dist.sweep();
    }

    function testRecoverySweepRevertsOnTide() public {
        vm.warp(endDate + 1);
        vm.prank(multisig);
        vm.expectRevert(IHarborTideDistributorErrors.CannotRecoverClaimToken.selector);
        dist.recoverySweep(address(tide));
    }

    function testRecoverySweepRevertsOnBao() public {
        vm.warp(endDate + 1);
        vm.prank(multisig);
        vm.expectRevert(IHarborTideDistributorErrors.CannotRecoverClaimToken.selector);
        dist.recoverySweep(address(bao));
    }

    function testRecoverySweepStrayToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(dist), 1_000e18);

        vm.warp(endDate + 1);
        vm.prank(multisig);
        dist.recoverySweep(address(stray));
        assertEq(stray.balanceOf(multisig), 1_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR / VIEWS
    //////////////////////////////////////////////////////////////*/

    function testConstructorRevertsOnBadDates() public {
        vm.expectRevert(IHarborTideDistributorErrors.InvalidDates.selector);
        new HarborTideDistributor_v1(
            address(tide),
            address(bao),
            address(ve),
            endDate,
            startDate,
            SNAPSHOT_BLOCK,
            multisig,
            bytes32(0),
            bytes32(0)
        );
    }

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(IHarborTideDistributorErrors.InvalidAddress.selector);
        new HarborTideDistributor_v1(
            address(0), address(bao), address(ve), startDate, endDate, SNAPSHOT_BLOCK, multisig, bytes32(0), bytes32(0)
        );
    }

    function testConversionRoundTrip() public view {
        // tideToBao rounds up, so round-trip never under-delivers TIDE
        assertGe(dist.baoToTide(dist.tideToBao(VE_TIDE)), VE_TIDE);
    }

    function testSupportsInterface() public view {
        assertTrue(dist.supportsInterface(type(IHarborTideDistributor).interfaceId));
        assertTrue(dist.supportsInterface(type(IHarborTideDistributorConfig).interfaceId));
    }
}

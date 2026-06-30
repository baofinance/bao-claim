// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HarborTideDistributor_v1} from "@tide/HarborTideDistributor_v1.sol";
import {IHarborTideDistributor} from "@tide/interfaces/IHarborTideDistributor.sol";
import {IHarborTideDistributorErrors} from "@tide/interfaces/IHarborTideDistributorErrors.sol";

/// @dev Mainnet fork integration tests against the deployed HarborTideDistributor_v1.
/// Run with logs: `script/test-fork.sh -vv` (loads `.env`) or `forge test --match-path test/tide/HarborTideDistributor_v1.fork.t.sol -vv --fork-url mainnet`
contract HarborTideDistributorV1ForkTest is Test {
    address internal constant DISTRIBUTOR = 0x1B12e5bae8be22D653D0833A70D951505d017BF9;
    address internal constant TIDE_TOKEN = 0xB324bA448Ac468015cB86039314ada42E198aA5c;
    address internal constant USER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    /// @dev Mainnet BAO holder for real-balance swap fork test (not merkle USER).
    address internal constant SWAP_USER = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
    address internal constant MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    /// @dev Fresh address for standard-root expansion fork test (not in initial tree).
    address internal constant NEW_STANDARD_USER = 0x1111111111111111111111111111111111111111;
    bytes32 internal constant MERKLE_ROOT = 0xfdd432ab8ae9cf7629c0b184dbe31ca5e8b0ebb00e58ea63594375090bfec563;

    uint256 internal constant CLAIM_TIDE = 692_340_796_268_698_531_702_446;
    uint256 internal constant EXPAND_TIDE = 1_000_000e18;
    uint256 internal constant FORK_FUNDING = 11_000_000e18; // mirrors live test funding

    HarborTideDistributor_v1 internal dist;
    IERC20 internal tide;
    IERC20 internal bao;

    /// @dev Live deploy may already have distributions; fork tests assert deltas from this snapshot.
    uint256 internal _baseTotalTideSwapAndVe;
    uint256 internal _baseTotalTideStandard;
    uint256 internal _baseUserBaoConverted;
    uint256 internal _baseSwapUserBaoConverted;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        dist = HarborTideDistributor_v1(DISTRIBUTOR);
        assertEq(address(dist.TIDE()), TIDE_TOKEN);
        tide = IERC20(TIDE_TOKEN);
        bao = IERC20(address(dist.BAO()));

        console2.log("=== fork setup ===");
        console2.log("  distributor:", DISTRIBUTOR);
        console2.log("  tide       :", TIDE_TOKEN);
        console2.log("  user       :", USER);
        console2.log("  merkle root:", uint256(MERKLE_ROOT));

        assertEq(dist.veBaoMerkleRoot(), MERKLE_ROOT);
        assertEq(dist.standardMerkleRoot(), MERKLE_ROOT);

        // Enter the claim window (fork block time may be before start or after end).
        if (block.timestamp < dist.startDate() || block.timestamp >= dist.endDate()) {
            vm.warp(dist.startDate() + 1);
        }
        assertLt(block.timestamp, dist.endDate());

        // Fund distributor on fork (live deploy may be unfunded — InsufficientBalance otherwise).
        deal(address(tide), DISTRIBUTOR, FORK_FUNDING);

        // Verify the supplied merkle proof matches the configured root.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(USER, CLAIM_TIDE))));
        assertTrue(MerkleProof.verify(_proof(), MERKLE_ROOT, leaf));

        IHarborTideDistributor.VeClaimStatus memory s = dist.getVeClaimStatus(USER, CLAIM_TIDE);
        assertTrue(s.canClaimNow, "USER should be ve-eligible on fork");

        console2.log("  claim TIDE amount:", CLAIM_TIDE);
        console2.log("  baoRequired     :", s.baoRequired);
        console2.log("  lockedAmount    :", s.lockedAmount);

        _baseTotalTideSwapAndVe = dist.totalTideSwapAndVe();
        _baseTotalTideStandard = dist.totalTideStandard();
        _baseUserBaoConverted = dist.baoConverted(USER);
        _baseSwapUserBaoConverted = dist.baoConverted(SWAP_USER);

        _logState("setup AFTER fund + window");
    }

    function testFork_SwapBaoForTide() public {
        uint256 swapBao = 600_000e18;
        assertGe(bao.balanceOf(SWAP_USER), swapBao, "SWAP_USER needs BAO on fork");

        uint256 tideBefore = tide.balanceOf(SWAP_USER);
        uint256 multisigBaoBefore = bao.balanceOf(MULTISIG);
        console2.log("  swap user            :", SWAP_USER);
        console2.log("  swap user BAO before :", bao.balanceOf(SWAP_USER));
        _logState("swap BEFORE");

        console2.log("  >> convertBao baoIn       :", swapBao);
        console2.log("  >> expected TIDE out      :", dist.baoToTide(swapBao));

        vm.startPrank(SWAP_USER);
        bao.approve(DISTRIBUTOR, swapBao);
        dist.convertBao(swapBao);
        vm.stopPrank();

        uint256 tideReceived = tide.balanceOf(SWAP_USER) - tideBefore;
        console2.log("  >> actual TIDE received  :", tideReceived);
        console2.log("  >> multisig BAO received :", bao.balanceOf(MULTISIG) - multisigBaoBefore);
        console2.log("  >> swap user BAO after   :", bao.balanceOf(SWAP_USER));
        _logState("swap AFTER");

        assertEq(tideReceived, dist.baoToTide(swapBao));
        assertEq(dist.baoConverted(SWAP_USER), _baseSwapUserBaoConverted + swapBao);
        assertEq(bao.balanceOf(MULTISIG), multisigBaoBefore + swapBao);
    }

    function testFork_ClaimVeBao() public {
        uint256 tideBefore = tide.balanceOf(USER);
        _logState("veClaim BEFORE");

        console2.log("  >> claimVeBao tideAmount :", CLAIM_TIDE);

        vm.prank(USER);
        dist.claimVeBao(CLAIM_TIDE, _proof());

        console2.log("  >> TIDE received         :", tide.balanceOf(USER) - tideBefore);
        _logState("veClaim AFTER");

        assertEq(tide.balanceOf(USER) - tideBefore, CLAIM_TIDE);
        assertTrue(dist.hasClaimedVeBao(USER));
    }

    function testFork_ClaimStandard() public {
        uint256 tideBefore = tide.balanceOf(USER);
        _logState("standardClaim BEFORE");

        console2.log("  >> claimStandard tideAmount:", CLAIM_TIDE);

        vm.prank(USER);
        dist.claimStandard(CLAIM_TIDE, _proof());

        console2.log("  >> TIDE received           :", tide.balanceOf(USER) - tideBefore);
        _logState("standardClaim AFTER");

        assertEq(tide.balanceOf(USER) - tideBefore, CLAIM_TIDE);
        assertTrue(dist.hasClaimedStandard(USER));
    }

    function testFork_ClaimVeBaoTwiceReverts() public {
        uint256 tideBefore = tide.balanceOf(USER);
        _logState("veDoubleClaim BEFORE #1");

        console2.log("  >> claimVeBao #1 tideAmount:", CLAIM_TIDE);
        vm.prank(USER);
        dist.claimVeBao(CLAIM_TIDE, _proof());

        console2.log("  >> TIDE received #1        :", tide.balanceOf(USER) - tideBefore);
        _logState("veDoubleClaim AFTER #1 (success)");

        console2.log("  >> claimVeBao #2 tideAmount:", CLAIM_TIDE, "(expect AlreadyClaimed revert)");
        vm.prank(USER);
        vm.expectRevert(IHarborTideDistributorErrors.AlreadyClaimed.selector);
        dist.claimVeBao(CLAIM_TIDE, _proof());

        console2.log("  >> claimVeBao #2 reverted as expected: AlreadyClaimed");
        _logState("veDoubleClaim AFTER #2 (unchanged)");

        assertEq(tide.balanceOf(USER) - tideBefore, CLAIM_TIDE, "no extra TIDE after revert");
        assertTrue(dist.hasClaimedVeBao(USER));
    }

    function testFork_ClaimStandardTwiceReverts() public {
        uint256 tideBefore = tide.balanceOf(USER);
        _logState("standardDoubleClaim BEFORE #1");

        console2.log("  >> claimStandard #1 tideAmount:", CLAIM_TIDE);
        vm.prank(USER);
        dist.claimStandard(CLAIM_TIDE, _proof());

        console2.log("  >> TIDE received #1           :", tide.balanceOf(USER) - tideBefore);
        _logState("standardDoubleClaim AFTER #1 (success)");

        console2.log("  >> claimStandard #2 tideAmount:", CLAIM_TIDE, "(expect AlreadyClaimed revert)");
        vm.prank(USER);
        vm.expectRevert(IHarborTideDistributorErrors.AlreadyClaimed.selector);
        dist.claimStandard(CLAIM_TIDE, _proof());

        console2.log("  >> claimStandard #2 reverted as expected: AlreadyClaimed");
        _logState("standardDoubleClaim AFTER #2 (unchanged)");

        assertEq(tide.balanceOf(USER) - tideBefore, CLAIM_TIDE, "no extra TIDE after revert");
        assertTrue(dist.hasClaimedStandard(USER));
    }

    function testFork_FullUserFlow_SwapVeAndStandard() public {
        uint256 swap1 = 600_000e18;
        uint256 swap2 = 400_000e18;
        uint256 expectedSwapTide = dist.baoToTide(swap1) + dist.baoToTide(swap2);
        uint256 tideBefore = tide.balanceOf(USER);

        _fundBao(USER, swap1 + swap2);
        _logState("fullFlow BEFORE");

        vm.startPrank(USER);
        _swap(swap1, "fullFlow swap #1");
        _swap(swap2, "fullFlow swap #2");
        _claimVe("fullFlow veClaim");
        _claimStandard("fullFlow standardClaim");
        vm.stopPrank();

        _logState("fullFlow FINAL");
        console2.log("  >> expected user TIDE total:", expectedSwapTide + CLAIM_TIDE + CLAIM_TIDE);
        console2.log("  >> actual user TIDE total  :", tide.balanceOf(USER) - tideBefore);

        assertEq(tide.balanceOf(USER) - tideBefore, expectedSwapTide + CLAIM_TIDE + CLAIM_TIDE);
        assertEq(dist.totalTideSwapAndVe(), _baseTotalTideSwapAndVe + expectedSwapTide + CLAIM_TIDE);
        assertEq(dist.totalTideStandard(), _baseTotalTideStandard + CLAIM_TIDE);
        assertTrue(dist.hasClaimedVeBao(USER));
        assertTrue(dist.hasClaimedStandard(USER));
    }

    function testFork_SweepToMultisig() public {
        uint256 leftover = tide.balanceOf(DISTRIBUTOR);
        assertGt(leftover, 0, "distributor should hold TIDE to sweep");

        _logState("sweep BEFORE (window open)");

        vm.warp(dist.endDate() + 1);
        assertGe(block.timestamp, dist.endDate());

        uint256 multisigTideBefore = tide.balanceOf(MULTISIG);
        console2.log("  >> sweep leftover TIDE   :", leftover);

        vm.prank(MULTISIG);
        dist.sweep();

        console2.log("  >> multisig TIDE received:", tide.balanceOf(MULTISIG) - multisigTideBefore);
        _logState("sweep AFTER");

        assertEq(tide.balanceOf(DISTRIBUTOR), 0);
        assertEq(tide.balanceOf(MULTISIG), multisigTideBefore + leftover);
    }

    /// @dev Claims ve + standard first, then swaps BAO — opposite order to fullFlow.
    function testFork_ClaimVeAndStandardThenSwap() public {
        uint256 swapBao = 500_000e18;
        uint256 expectedSwapTide = dist.baoToTide(swapBao);
        uint256 tideBefore = tide.balanceOf(USER);

        _logState("claimsThenSwap BEFORE");

        vm.startPrank(USER);
        _claimVe("claimsThenSwap veClaim");
        _claimStandard("claimsThenSwap standardClaim");
        vm.stopPrank();

        _fundBao(USER, swapBao);

        vm.startPrank(USER);
        _swap(swapBao, "claimsThenSwap swap after claims");
        vm.stopPrank();

        uint256 totalTide = tide.balanceOf(USER) - tideBefore;
        _logState("claimsThenSwap FINAL");
        console2.log("  >> expected user TIDE total:", CLAIM_TIDE + CLAIM_TIDE + expectedSwapTide);
        console2.log("  >> actual user TIDE total  :", totalTide);

        assertEq(totalTide, CLAIM_TIDE + CLAIM_TIDE + expectedSwapTide);
        assertTrue(dist.hasClaimedVeBao(USER));
        assertTrue(dist.hasClaimedStandard(USER));
        assertEq(dist.baoConverted(USER), _baseUserBaoConverted + swapBao);
        assertEq(dist.totalTideSwapAndVe(), _baseTotalTideSwapAndVe + CLAIM_TIDE + expectedSwapTide);
        assertEq(dist.totalTideStandard(), _baseTotalTideStandard + CLAIM_TIDE);
    }

    function testFork_UpdateStandardMerkleRootDuringWindow() public {
        assertGe(block.timestamp, dist.startDate());
        assertLt(block.timestamp, dist.endDate());
        assertFalse(dist.hasClaimedStandard(NEW_STANDARD_USER));

        bytes32 veRootBefore = dist.veBaoMerkleRoot();
        bytes32 stdRootBefore = dist.standardMerkleRoot();
        bytes32 expandedRoot = _leaf(NEW_STANDARD_USER, EXPAND_TIDE);

        console2.log("  standard root before:", uint256(stdRootBefore));
        console2.log("  standard root after :", uint256(expandedRoot));

        vm.prank(MULTISIG);
        dist.setStandardMerkleRoot(expandedRoot);

        assertEq(dist.standardMerkleRoot(), expandedRoot);
        assertEq(dist.veBaoMerkleRoot(), veRootBefore, "ve root unchanged");

        vm.prank(MULTISIG);
        vm.expectRevert(IHarborTideDistributorErrors.ConfigLocked.selector);
        dist.setVeBaoMerkleRoot(keccak256("blocked during window"));

        uint256 tideBefore = tide.balanceOf(NEW_STANDARD_USER);
        vm.prank(NEW_STANDARD_USER);
        dist.claimStandard(EXPAND_TIDE, _emptyProof());

        console2.log("  >> expand user TIDE received:", tide.balanceOf(NEW_STANDARD_USER) - tideBefore);
        assertEq(tide.balanceOf(NEW_STANDARD_USER) - tideBefore, EXPAND_TIDE);
        assertTrue(dist.hasClaimedStandard(NEW_STANDARD_USER));
        assertEq(dist.totalTideStandard(), _baseTotalTideStandard + EXPAND_TIDE);
    }

    function _fundBao(address user, uint256 amount) internal {
        deal(address(bao), user, amount);
        vm.prank(user);
        bao.approve(DISTRIBUTOR, type(uint256).max);
        console2.log("  >> funded + approved BAO  :", amount);
    }

    function _swap(uint256 baoIn, string memory label) internal {
        uint256 tideBefore = tide.balanceOf(USER);
        console2.log("  >> convertBao baoIn       :", baoIn);
        console2.log("  >> expected TIDE out      :", dist.baoToTide(baoIn));
        dist.convertBao(baoIn);
        console2.log("  >> actual TIDE received  :", tide.balanceOf(USER) - tideBefore);
        _logState(label);
    }

    function _claimVe(string memory label) internal {
        uint256 tideBefore = tide.balanceOf(USER);
        console2.log("  >> claimVeBao tideAmount :", CLAIM_TIDE);
        dist.claimVeBao(CLAIM_TIDE, _proof());
        console2.log("  >> TIDE received         :", tide.balanceOf(USER) - tideBefore);
        _logState(label);
    }

    function _claimStandard(string memory label) internal {
        uint256 tideBefore = tide.balanceOf(USER);
        console2.log("  >> claimStandard tideAmount:", CLAIM_TIDE);
        dist.claimStandard(CLAIM_TIDE, _proof());
        console2.log("  >> TIDE received           :", tide.balanceOf(USER) - tideBefore);
        _logState(label);
    }

    function _logState(string memory label) internal view {
        console2.log("---", label, "---");
        console2.log("  user TIDE            :", tide.balanceOf(USER));
        console2.log("  user BAO             :", bao.balanceOf(USER));
        console2.log("  multisig BAO         :", bao.balanceOf(MULTISIG));
        console2.log("  multisig TIDE        :", tide.balanceOf(MULTISIG));
        console2.log("  dist TIDE balance    :", tide.balanceOf(DISTRIBUTOR));
        console2.log("  totalBaoConverted    :", dist.totalBaoConverted());
        console2.log("  totalTideSwapAndVe   :", dist.totalTideSwapAndVe());
        console2.log("  totalTideStandard    :", dist.totalTideStandard());
        console2.log("  hasClaimedVeBao      :", dist.hasClaimedVeBao(USER));
        console2.log("  hasClaimedStandard   :", dist.hasClaimedStandard(USER));
    }

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _emptyProof() internal pure returns (bytes32[] memory proof) {
        return new bytes32[](0);
    }

    function _proof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](10);
        proof[0] = 0xae7d48372e5cac6ba8ad120f0de183bc31de76796f55a4a8a4d1a82951a444bc;
        proof[1] = 0x7a0f7455c35c133da511f5441e3988bcc83511944341a7551d5474f2fd4abee1;
        proof[2] = 0x09e0f461aad3a19ed3c138369bf055fc30942fed390630d67749a3f1d508b898;
        proof[3] = 0x6a9fd4a632c1f2bbf7e9cb1e219234d6bf07297c5d38de6c5e670f3a56130128;
        proof[4] = 0x6b6cb3393c36cf1797a2ff876cf419add88a6a5a273e195ccea8cfd101f89a4d;
        proof[5] = 0xc03d0c361d04589d9613b58820b4082a2ef2742defa0c1d84912b15f566d1bf0;
        proof[6] = 0x60c7c37bd009361a906d488f43f86ebf9f1db37b095c25409e3ea03cd56d4069;
        proof[7] = 0x7c02b28b5be8db7c29812affd8f9d763fdabaf94694dd9c77d3d633b308bd8b8;
        proof[8] = 0xe0a7d3467b99a60e9aca7e45f65bb7a39fa25255d627b37ea1487df2156c11ae;
        proof[9] = 0x2ae5010b1291aa7cb3493febabf68cce736bc90afe974874007520502c763473;
    }
}

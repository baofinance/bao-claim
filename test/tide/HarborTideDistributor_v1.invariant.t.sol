// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {HarborTideDistributor_v1} from "@tide/HarborTideDistributor_v1.sol";

import {MockERC20} from "@tide-test-mocks/MockERC20.sol";
import {MockVotingEscrow} from "@tide-test-mocks/MockVotingEscrow.sol";

/// @dev Fuzz handler for cap-safety invariants on HarborTideDistributor_v1.
contract HarborTideDistributorHandler is Test {
    HarborTideDistributor_v1 public dist;
    MockERC20 public tide;
    MockERC20 public bao;
    MockVotingEscrow public ve;

    address public multisig = address(0xB0B0);
    address public actor = address(0xA11CE);

    uint256 public startDate;
    uint256 public endDate;
    uint256 public constant SNAPSHOT_BLOCK = 100;
    uint256 public constant FUNDING = 280_000_000e18;
    uint256 public constant VE_TIDE = 1_000_000e18;
    uint256 public constant STD_TIDE = 500_000e18;

    uint256 public tideFunded;

    constructor() {
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
            _leaf(actor, VE_TIDE),
            _leaf(actor, STD_TIDE)
        );

        tide.mint(address(dist), FUNDING);
        tideFunded = FUNDING;

        ve.setSnapshot(actor, 10_000_000e18);
        ve.setLocked(actor, int128(uint128(12_000_000e18)), endDate + 30 days);

        vm.warp(startDate + 1);
    }

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function convertBao(uint256 baoAmount) external {
        uint256 minBao = dist.tideToBao(dist.MIN_TIDE_OUT());
        baoAmount = bound(baoAmount, minBao, 10_000_000e18);

        bao.mint(actor, baoAmount);
        vm.startPrank(actor);
        bao.approve(address(dist), baoAmount);
        try dist.convertBao(baoAmount) {} catch {}
        vm.stopPrank();
    }

    function claimVeBao() external {
        if (dist.hasClaimedVeBao(actor)) return;

        vm.prank(actor);
        try dist.claimVeBao(VE_TIDE, new bytes32[](0)) {} catch {}
    }

    function claimStandard() external {
        if (dist.hasClaimedStandard(actor)) return;

        vm.prank(actor);
        try dist.claimStandard(STD_TIDE, new bytes32[](0)) {} catch {}
    }
}

contract HarborTideDistributorV1InvariantTest is StdInvariant, Test {
    HarborTideDistributorHandler public handler;

    function setUp() public {
        handler = new HarborTideDistributorHandler();
        targetContract(address(handler));
    }

    function invariant_capsNeverExceeded() public view {
        HarborTideDistributor_v1 dist = handler.dist();

        assertLe(dist.totalTideSwapAndVe(), dist.MAX_TIDE_SWAP_AND_VE());
        assertLe(dist.totalTideStandard(), dist.MAX_TIDE_STANDARD());
        assertLe(dist.totalBaoConverted(), dist.MAX_BAO());
    }

    function invariant_noOverDistribution() public view {
        HarborTideDistributor_v1 dist = handler.dist();
        MockERC20 tide = handler.tide();

        uint256 distributed = dist.totalTideSwapAndVe() + dist.totalTideStandard();
        assertLe(distributed, handler.tideFunded());
        assertEq(tide.balanceOf(address(dist)) + distributed, handler.tideFunded());
    }
}

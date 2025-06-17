// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BaoClaim.sol";
import "forge-std/console.sol";

contract BaoClaimTest is Test {
    BaoClaim public claimContract;
    MockERC20 public token;

    address public multisig = address(0x3dFc49e5112005179Da613BdE5973229082dAc35);
    address public claimer = address(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
    bytes32 public root = 0x8eabd2b36ce185476a0bda6c61aa1584dcad3b6f0ed59b5edc5d23e451f6e290;
    bytes32[] public proof;
    uint256 public initialSupply = 50_000_000 * 1e18;

    function setUp() public {
        token = new MockERC20();
        uint256 start = block.timestamp + 2 days;
        uint256 end = start + 7 days;

        claimContract = new BaoClaim(root, start, end, multisig, address(token), 10_581e18);
        token.mint(address(claimContract), initialSupply);

        proof.push(0x60f5c088967371383ec13d554a2870a21c579acccabcf082f3af690c5c67c91f);
        proof.push(0xe71344f8df6c09b676b64d848db171be9469a3937750db0ba8c5d8f652115345);
        proof.push(0xc8dbd1d8a6cabde2f317650770e7add02013fac153f2e2038169e1053842a00e);
        proof.push(0xc1c107c890914b2533f01c9a6dc9fa659e650b7f3e0ffbdf70a483895a3445d5);
        proof.push(0xd40f9f92b6eb453023f28b89ffd69f450c5be14d30bc8041bfff90823b5b569b);
        proof.push(0xd31865452354793806ae08a5cb98b7ada83741cff32da4a0afefd247f4c27094);
        proof.push(0x7a8d0195e06276c08956fae30aba58b60a64dddf1448987cbbf7eafb694b1253);
        proof.push(0x846d99699879325ca4157036fa13a720f40803bdb41b5f33e9df7d503fe7d7e6);
        proof.push(0x24b5b381d0bbc2bb5a15979d78016acf1a94efcd9a5f0e9815c1f5daf120d325);
        proof.push(0x7e95e9476c66223237806869f61f55085cd5032bc125181d02589684cb746914);
    }

    function testCanClaim() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(claimer);
        claimContract.claim(proof);

        uint256 claimed = claimContract.claimAmount();
        assertEq(token.balanceOf(claimer), claimed);
        assertTrue(claimContract.hasClaimed(claimer));
    }

    function testCannotClaimTwice() public {
        vm.warp(claimContract.startDate() + 1);

        vm.prank(claimer);
        claimContract.claim(proof);

        uint256 claimed = claimContract.claimAmount();
        assertEq(token.balanceOf(claimer), claimed);
        assertTrue(claimContract.hasClaimed(claimer));

        vm.expectRevert(BaoClaim.AlreadyClaimed.selector);
        vm.prank(claimer);
        claimContract.claim(proof);
    }

    function testRevertsBeforeStart() public {
        uint256 futureStart = block.timestamp + 1 days;
        BaoClaim futureClaim = new BaoClaim(root, futureStart, futureStart + 7 days, multisig, address(token), 10_581e18);
        token.mint(address(futureClaim), initialSupply);

        vm.expectRevert(BaoClaim.ClaimNotStarted.selector);
        vm.prank(claimer);
        futureClaim.claim(proof);
    }

    function testCannotSweepEarly() public {
        vm.prank(multisig);
        vm.expectRevert(BaoClaim.ClaimNotOver.selector);
        claimContract.sweep();
    }

    function testCanSweepAfterEnd() public {
        vm.warp(claimContract.endDate() + 1);

        uint256 beforeSweep = token.balanceOf(multisig);

        vm.prank(multisig);
        claimContract.sweep();

        uint256 afterSweep = token.balanceOf(multisig);
        assertGt(afterSweep, beforeSweep);
    }

    function testSetMerkleRootBeforeOrAfterClaimWindow() public {
        bytes32 newRoot = keccak256("new root");
        vm.prank(multisig);
        claimContract.setMerkleRoot(newRoot);
        assertEq(claimContract.merkleRoot(), newRoot);
    }

    function testSetMerkleRootDuringClaimWindowReverts() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(multisig);
        vm.expectRevert(BaoClaim.ClaimWindowActive.selector);
        claimContract.setMerkleRoot(keccak256("fail root"));
    }

    function testSetDatesBeforeorAfterClaimWindow() public {
        uint256 newStart = block.timestamp + 2 days;
        uint256 newEnd = newStart + 7 days;
        vm.prank(multisig);
        claimContract.setDates(newStart, newEnd);
        assertEq(claimContract.startDate(), newStart);
        assertEq(claimContract.endDate(), newEnd);
    }

    function testSetDatesDuringClaimWindowReverts() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(multisig);
        vm.expectRevert(BaoClaim.ClaimWindowActive.selector);
        claimContract.setDates(block.timestamp + 3 days, block.timestamp + 10 days);
    }

    function testCanRecoverNonClaimTokenAfterEnd() public {
        MockERC20 foreignToken = new MockERC20();
        foreignToken.mint(address(claimContract), 1_000e18);

        vm.warp(claimContract.endDate() + 1);
        uint256 before = foreignToken.balanceOf(multisig);

        vm.prank(multisig);
        claimContract.recoverySweep(address(foreignToken));

        uint256 after_ = foreignToken.balanceOf(multisig);
        assertEq(after_, before + 1_000e18);
    }

    function testCannotRecoverClaimToken() public {
        vm.warp(claimContract.endDate() + 1);
        vm.prank(multisig);
        vm.expectRevert(BaoClaim.CannotRecoverClaimToken.selector);
        claimContract.recoverySweep(address(token));
    }

    function testCannotRecoverBeforeEnd() public {
        MockERC20 foreignToken = new MockERC20();
        foreignToken.mint(address(claimContract), 1_000e18);

        vm.prank(multisig);
        vm.expectRevert(BaoClaim.ClaimNotOver.selector);
        claimContract.recoverySweep(address(foreignToken));
    }

    function testSetClaimAmountBeforeWindow() public {
        uint256 newAmount = 1_234e18;
        vm.prank(multisig);
        claimContract.setClaimAmount(newAmount);
        assertEq(claimContract.claimAmount(), newAmount);
    }

    function testSetClaimAmountDuringWindowReverts() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(multisig);
        vm.expectRevert(BaoClaim.ClaimWindowActive.selector);
        claimContract.setClaimAmount(1_234e18);
    }

    function testGetClaimableView() public {
        (bool claimed, uint256 amount) = claimContract.getClaimable(claimer);
        assertEq(claimed, false);
        assertEq(amount, claimContract.claimAmount());

        vm.warp(claimContract.startDate() + 1);
        vm.prank(claimer);
        claimContract.claim(proof);

        (claimed, ) = claimContract.getClaimable(claimer);
        assertEq(claimed, true);
    }
}

contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}
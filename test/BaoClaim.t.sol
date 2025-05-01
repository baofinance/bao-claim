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
    bytes32 public root = 0x71faa1285a27e55d40a910ae6f35112cc04799967ba8e2cc8f34ed4c09667796;
    bytes32[] public proof;
    uint256 public initialSupply = 50_000_000 * 1e18;

    function setUp() public {
        token = new MockERC20();
        uint256 start = block.timestamp + 2 days;
        uint256 end = start + 7 days;

        claimContract = new BaoClaim(root, start, end, multisig, address(token));
        token.mint(address(claimContract), initialSupply);

        proof.push(0x8e7e55115e8d71696d6ebf2269585e9f05c5ab1b926aa25f3181c6ac8301e879);
        proof.push(0x60b7a778e98bd8df5b1dda9fb9ba8bbfc9e3616696da2ce2a1a049c0f0dba2bb);
        proof.push(0x929bda64987dd2a724d22e9dd37cac41fb5365f72d5c66e358c0c2a513803321);
        proof.push(0x36659f2236bb12f74467b58bc2bcd949a96d6d03ca2c40ec469711d2414e7b97);
        proof.push(0x0ebbc8fb1f95853ffcf321d3062f9272c0615d8a9d3e66a6c91b1b2f6b84b1ad);
        proof.push(0x888d83b349e51d645e827293ecb619619fb805958f386521b593db7785d6b87b);
        proof.push(0x23ea5fb85369b1dff3905dd4a2652d8ee8de02b4f42d9ba31dfcd15727965bd7);
        proof.push(0x70de93173404e6a7b838775917cd3ebe21fb2faa732b849c3612f0f6e9ba0e2b);
        proof.push(0x8c52b79cd91dcae2fd381068e9c071695a87dd9d83c6f090fe453705baeebefa);
        proof.push(0xb9cb35084c813422817a4778d823822f89573066b3319c06aff7f0d6b43264df);
        proof.push(0xa97e9c6be9babe3185a20f95bb19c8452f12d19684cd50ba6872cfdcfb54e5ff);
        proof.push(0x090d9d871b0221408a2bbbee02228f841a36551fb7d40b11508066d5b20f6759);
        proof.push(0xf8dcc0dc0c92192090e12aa981fc2a764377399808fd6cc2307fda40cb7bff5f);
    }

    function testPrintRoot() public {
        //console.log("Merkle Root:");
        //console.logBytes32(claimContract.merkleRoot());
    }

    function testCanClaim() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(claimer);
        claimContract.claim(proof);

        uint256 claimed = claimContract.CLAIM_AMOUNT();
        assertEq(token.balanceOf(claimer), claimed);
        assertTrue(claimContract.hasClaimed(claimer));

        //console.log("Claim successful for", claimed / 1e18, "tokens");
    }

    function testCannotClaimTwice() public {
        vm.warp(claimContract.startDate() + 1);

        vm.prank(claimer);
        claimContract.claim(proof);

        uint256 claimed = claimContract.CLAIM_AMOUNT();
        assertEq(token.balanceOf(claimer), claimed);
        assertTrue(claimContract.hasClaimed(claimer));
        //console.log("First claim successful for", claimed / 1e18, "tokens");

        //console.log("Expecting revert with AlreadyClaimed selector:");
        //console.logBytes4(BaoClaim.AlreadyClaimed.selector);
        vm.expectRevert(BaoClaim.AlreadyClaimed.selector);
        vm.prank(claimer);
        claimContract.claim(proof);
    }

    function testRevertsBeforeStart() public {
        uint256 futureStart = block.timestamp + 1 days;
        BaoClaim futureClaim = new BaoClaim(root, futureStart, futureStart + 7 days, multisig, address(token));

        token.mint(address(futureClaim), initialSupply);

        //console.log("Expecting revert with ClaimNotStarted selector:");
        //console.logBytes4(BaoClaim.ClaimNotStarted.selector);
        vm.expectRevert(BaoClaim.ClaimNotStarted.selector);
        vm.prank(claimer);
        futureClaim.claim(proof);
    }

    function testCannotSweepEarly() public {
        vm.prank(multisig);
        //console.log("Expecting revert with ClaimNotOver selector:");
        //console.logBytes4(BaoClaim.ClaimNotOver.selector);
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

        //console.log("Sweeped successful for", afterSweep / 1e18, "tokens");
    }

    function testSetMerkleRootBeforeOrAfterClaimWindow() public {
        bytes32 newRoot = keccak256("new root");
        vm.prank(multisig);
        claimContract.setMerkleRoot(newRoot);
        assertEq(claimContract.merkleRoot(), newRoot);

        //console.log("Successfully set new root:");
        //console.logBytes32(newRoot);
    }

    function testSetMerkleRootDuringClaimWindowReverts() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(multisig);
        //console.log("Expecting revert with ClaimWindowActive selector:");
        //console.logBytes4(BaoClaim.ClaimWindowActive.selector);
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

        //console.log("Successfully set new startDate and endDate:");
        //console.log("startDate:");
        //console.logUint(newStart);
        //console.log("endDate:");
        //console.logUint(newEnd);
    }

    function testSetDatesDuringClaimWindowReverts() public {
        vm.warp(claimContract.startDate() + 1);
        vm.prank(multisig);
        //console.log("Expecting revert with ClaimWindowActive selector:");
        //console.logBytes4(BaoClaim.ClaimWindowActive.selector);
        vm.expectRevert(BaoClaim.ClaimWindowActive.selector);
        claimContract.setDates(block.timestamp + 3 days, block.timestamp + 10 days);
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

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/ZhengLongIDO.sol";

contract MockERC20 is IERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract ZhengLongIDOTest is Test {
    ZhengLongIDO public ido;
    MockERC20 public usdc;

    address public multisig = address(0x3dFc49e5112005179Da613BdE5973229082dAc35);
    address public buyer = address(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
    address public buyer2 = address(0xeBf87396267A4829B3a1a3EDb400246A9BE07723);
    bytes32 public root;
    bytes32[] public proof;
    bytes32[] public proof2;

    function setUp() public {
        usdc = new MockERC20();

        // Merkle tree setup
        root = 0x8eabd2b36ce185476a0bda6c61aa1584dcad3b6f0ed59b5edc5d23e451f6e290;
        
        // Proof for buyer
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

        // Proof for buyer2
        proof2.push(0xec3ae122c7da0771aedbdb15b28028f48dc32c28a599c9ba2ddae98b081c608b);
        proof2.push(0x64400729196c7523c7f2122e68a097ad31fb0ade087a45f52c5a8cfb69844278);
        proof2.push(0xf6444b84e92027b78431d3bd8ff6e401194519f42c51722004125613041e1fa0);
        proof2.push(0x3cd85454daeaed1037d7ba18d5e69ad2f3926cea2875be523845aead312942ca);
        proof2.push(0xcf829a22b07f9cfbf21c231728c4fa7ca9efd9c4058a6d4855e3a9db1a98c515);
        proof2.push(0x6d296ac0c461ad3d8db889d38761655af2eda7a83e6851d0d134c295ad573a4b);
        proof2.push(0x7a8d0195e06276c08956fae30aba58b60a64dddf1448987cbbf7eafb694b1253);
        proof2.push(0x846d99699879325ca4157036fa13a720f40803bdb41b5f33e9df7d503fe7d7e6);
        proof2.push(0x24b5b381d0bbc2bb5a15979d78016acf1a94efcd9a5f0e9815c1f5daf120d325);
        proof2.push(0x7e95e9476c66223237806869f61f55085cd5032bc125181d02589684cb746914);

        ido = new ZhengLongIDO(
            address(usdc),
            multisig,
            root,
            block.timestamp + 1 days,
            block.timestamp + 2 days
        );

        // Setup both buyers
        usdc.mint(buyer, 100_000_000);
        usdc.mint(buyer2, 100_000_000);
        vm.prank(buyer);
        usdc.approve(address(ido), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(ido), type(uint256).max);
    }

    function testCannotDepositBeforeSaleStart() public {
        vm.prank(buyer);
        vm.expectRevert(ZhengLongIDO.SaleNotStarted.selector);
        ido.deposit(1_000_000, proof);
    }

    function testCannotDepositAfterSaleEnd() public {
        vm.warp(ido.end() + 1);
        vm.prank(buyer);
        vm.expectRevert(ZhengLongIDO.SaleEnded.selector);
        ido.deposit(1_000_000, proof);
    }

    function testCannotDepositZeroAmount() public {
        vm.warp(ido.start() + 1);
        vm.prank(buyer);
        vm.expectRevert(ZhengLongIDO.ZeroDeposit.selector);
        ido.deposit(0, proof);
    }

    function testCannotDepositIfNotWhitelisted() public {
        // Prepare a non-whitelisted address
        address nonWhitelisted = address(0xabc);
        usdc.mint(nonWhitelisted, 10_000_000);
        vm.prank(nonWhitelisted);
        usdc.approve(address(ido), type(uint256).max);

        // Advance to within the sale window
        vm.warp(ido.start() + 1);

        // Use an invalid proof (empty array) — will fail Merkle verification
        bytes32[] memory badProof;

        vm.prank(nonWhitelisted);
        vm.expectRevert(ZhengLongIDO.InvalidProof.selector);
        ido.deposit(1_000_000, badProof);
    }

    function testSuccessfulDeposit() public {
        vm.warp(ido.start() + 1);
        uint256 initialBalance = usdc.balanceOf(multisig);

        vm.prank(buyer);
        ido.deposit(3_000_000, proof);

        assertEq(usdc.balanceOf(multisig), initialBalance + 3_000_000);
        assertEq(ido.totalDeposited(), 3_000_000);
        assertEq(ido.userDeposits(buyer), 3_000_000);
    }

    function testMultipleDepositsAccumulate() public {
        vm.warp(ido.start() + 1);

        vm.prank(buyer);
        ido.deposit(2_000_000, proof);

        vm.prank(buyer);
        ido.deposit(1_000_000, proof);

        assertEq(ido.userDeposits(buyer), 3_000_000);
        assertEq(ido.totalDeposited(), 3_000_000);
    }

    function testSetMerkleRoot() public {
        vm.prank(ido.owner());
        bytes32 newRoot = keccak256("new root");
        ido.setMerkleRoot(newRoot);
        assertEq(ido.merkleRoot(), newRoot);
    }

    function testSetDates() public {
        vm.prank(ido.owner());
        uint256 newStart = block.timestamp + 10 days;
        uint256 newEnd = newStart + 5 days;
        ido.setDates(newStart, newEnd);
        assertEq(ido.start(), newStart);
        assertEq(ido.end(), newEnd);
    }

    function testSetMultisig() public {
        vm.prank(ido.owner());
        address newMultisig = address(0x1234);
        ido.setMultisig(newMultisig);
        assertEq(ido.multisig(), newMultisig);
    }

    function testSweepFailsIfNothing() public {
        vm.prank(ido.owner());
        vm.expectRevert(ZhengLongIDO.NothingToSweep.selector);
        ido.sweep(address(usdc));
    }

    function testSweepTransfersTokens() public {
        usdc.mint(address(ido), 1_000_000);
        vm.prank(ido.owner());
        ido.sweep(address(usdc));
        assertEq(usdc.balanceOf(multisig), 1_000_000);
    }

    function testIsSaleActive() public {
        assertFalse(ido.isSaleActive());
        vm.warp(ido.start() + 1);
        assertTrue(ido.isSaleActive());
    }

        function testUniqueDepositorTracking() public {
        vm.warp(ido.start() + 1);
        
        // First deposit from buyer
        vm.prank(buyer);
        ido.deposit(1_000_000, proof);
        
        assertEq(ido.totalDepositors(), 1);
        
        // First deposit from buyer2
        vm.prank(buyer2);
        ido.deposit(2_000_000, proof2);
        
        assertEq(ido.totalDepositors(), 2);
        
        // Second deposit from buyer doesn't increment counter
        vm.prank(buyer);
        ido.deposit(500_000, proof);
        
        assertEq(ido.totalDepositors(), 2);
    }

    function testDepositEventIncludesTotal() public {
    vm.warp(ido.start() + 1);
    
    // Expected event signature: Deposited(address indexed user, uint256 amount, uint256 totalUserDeposits)
    vm.expectEmit(true, true, true, true);
    emit ZhengLongIDO.Deposited(buyer, 1_000_000, 1_000_000);
    vm.prank(buyer);
    ido.deposit(1_000_000, proof);
    
    vm.expectEmit(true, true, true, true);
    emit ZhengLongIDO.Deposited(buyer, 500_000, 1_500_000);
    vm.prank(buyer);
    ido.deposit(500_000, proof);
    }

    function testGetUserDepositView() public {
        vm.warp(ido.start() + 1);
        
        vm.prank(buyer);
        ido.deposit(3_000_000, proof);
        
        assertEq(ido.getUserDeposit(buyer), 3_000_000);
        assertEq(ido.getUserDeposit(buyer2), 0); // Not deposited yet
    }

    function testGetTotalDepositsView() public {
        vm.warp(ido.start() + 1);
        
        assertEq(ido.getTotalDeposits(), 0);
        
        vm.prank(buyer);
        ido.deposit(1_000_000, proof);
        assertEq(ido.getTotalDeposits(), 1_000_000);
        
        vm.prank(buyer2);
        ido.deposit(2_000_000, proof2);
        assertEq(ido.getTotalDeposits(), 3_000_000);
    }

    function testGetDepositorCountView() public {
        vm.warp(ido.start() + 1);
        
        assertEq(ido.getDepositorCount(), 0);
        
        vm.prank(buyer);
        ido.deposit(1_000_000, proof);
        assertEq(ido.getDepositorCount(), 1);
        
        vm.prank(buyer2);
        ido.deposit(1_000_000, proof2);
        assertEq(ido.getDepositorCount(), 2);
    }

    function testImmutableUSDC() public view {
    // Simply verify the USDC address is set correctly
    assertEq(address(ido.usdc()), address(usdc));
    }
}

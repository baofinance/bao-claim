// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BaoIDO.sol";

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

contract BaoIDOTest is Test {
    BaoIDO public ido;
    MockERC20 public usdc;
    address public multisig = address(0xdeadbeef);
    address public buyer = address(0xbeefcafe);
    bytes32 public root;
    bytes32[] public proof;
    uint256 public discountPrice = 1_000_000; // 1.00 USDC
    uint256 public fullPrice = 2_000_000;     // 2.00 USDC

    function setUp() public {
        usdc = new MockERC20();
        root = keccak256(abi.encodePacked(buyer, uint256(5))); // maxDiscounted = 5
        ido = new BaoIDO(address(usdc), multisig, root, block.timestamp + 1 days, block.timestamp + 2 days, discountPrice, fullPrice);

        usdc.mint(buyer, 100_000_000); // 100 USDC
        vm.prank(buyer);
        usdc.approve(address(ido), type(uint256).max);

        // Generate actual proof (example)
        proof = new bytes32[](1);
        proof[0] = bytes32(0x71faa1285a27e55d40a910ae6f35112cc04799967ba8e2cc8f34ed4c09667796); // Replace with actual proof
    }

    function testCannotPurchaseBeforeStart() public {
        vm.prank(buyer);
        vm.expectRevert(BaoIDO.SaleNotStarted.selector);
        ido.purchase(1, 2, 5, proof);
    }

    function testCanPurchaseWithinWindow() public {
        vm.warp(ido.start() + 1 hours);
        
        uint256 initialTreasuryBalance = usdc.balanceOf(multisig);
        uint256 discountedShares = 2;
        uint256 totalShares = 4;
        
        vm.prank(buyer);
        ido.purchase(discountedShares, totalShares, 5, proof);

        // Verify purchase info
        (uint256 total, uint256 discounted, uint256 full) = ido.purchases(buyer);
        assertEq(total, totalShares);
        assertEq(discounted, discountedShares);
        assertEq(full, totalShares - discountedShares);
        
        // Verify USDC transfer
        uint256 expectedCost = (discountedShares * discountPrice) + (full * fullPrice);
        assertEq(usdc.balanceOf(multisig), initialTreasuryBalance + expectedCost);
    }

    function testAdminFunctions() public {
        vm.startPrank(ido.owner());
        
        // Test merkle root update
        bytes32 newRoot = keccak256("newroot");
        ido.setMerkleRoot(newRoot);
        assertEq(ido.merkleRoot(), newRoot);
        
        // Test price update
        ido.setPrices(500_000, 1_500_000);
        assertEq(ido.discountPrice(), 500_000);
        assertEq(ido.fullPrice(), 1_500_000);
        
        // Test date update
        uint256 newStart = block.timestamp + 10 days;
        uint256 newEnd = newStart + 10 days;
        ido.setDates(newStart, newEnd);
        assertEq(ido.start(), newStart);
        assertEq(ido.end(), newEnd);
        
        // Test multisig update
        address newMultisig = address(0x1234);
        ido.setMultisig(newMultisig);
        assertEq(ido.multisig(), newMultisig);
        
        vm.stopPrank();
    }

    function testSweepFailsIfEmpty() public {
        vm.prank(ido.owner());
        vm.expectRevert(BaoIDO.NothingToSweep.selector);
        ido.sweep(address(usdc));
    }

    function testSweepTransfersFunds() public {
        usdc.mint(address(ido), 1_000_000);
        vm.prank(ido.owner());
        ido.sweep(address(usdc));
        assertEq(usdc.balanceOf(multisig), 1_000_000);
    }

    function testIsSaleActive() public {
        assertFalse(ido.isSaleActive());
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(ido.isSaleActive());
    }

    function testIsOverSubscribed() public {
        vm.warp(block.timestamp + 1 days + 1);
        for (uint256 i = 0; i < 7; i++) {
            address user = address(uint160(i + 100));
            usdc.mint(user, 10_000_000);
            vm.prank(user);
            usdc.approve(address(ido), type(uint256).max);
            vm.prank(user);
            ido.purchase(0, 1_000_000, 0, proof); // force oversubscription
        }
        assertTrue(ido.isOverSubscribed());
    }
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SealedBidTender.sol";
import "../src/mechanisms/VickreyAward.sol";

/// @dev A contract that rejects every payment.
contract RejectingRecipient {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev ERC-20 whose transfer and transferFrom return nothing, like USDT on mainnet.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Regression tests for the three issues fixed in the hardening pass:
///      unbounded bidders, a rejecting slash recipient, and ERC-20s without return values.
contract HardeningTest is Test {
    VickreyAward vk;
    SealedBidTender tender;
    uint256 constant BOND = 1 ether;

    function setUp() public {
        vk = new VickreyAward();
        tender = new SealedBidTender();
    }

    function _terms(address recipient, uint256 maxBidders, address asset)
        internal
        view
        returns (ISealedBidTender.TenderTerms memory)
    {
        return ISealedBidTender.TenderTerms({
            targetRef: bytes32(uint256(1)),
            mechanism: address(vk),
            reserve: type(uint128).max,
            units: 1,
            commitDeadline: uint64(block.timestamp + 100),
            revealDeadline: uint64(block.timestamp + 200),
            bond: BOND,
            bondAsset: asset,
            slashRecipient: recipient,
            maxBidders: maxBidders
        });
    }

    function _bidder(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    // ── 1. bounded bidders ─────────────────────────────────────────────────────

    function test_maxBiddersRange() public {
        vm.expectRevert(bytes("maxBidders out of range"));
        tender.openTender(_terms(address(0xBEEF), 0, address(0)));
        uint256 tooMany = tender.MAX_BIDDERS() + 1;
        vm.expectRevert(bytes("maxBidders out of range"));
        tender.openTender(_terms(address(0xBEEF), tooMany, address(0)));
    }

    function test_tenderFull() public {
        bytes32 id = tender.openTender(_terms(address(0xBEEF), 2, address(0)));
        for (uint256 i; i < 2; i++) {
            vm.deal(_bidder(i), BOND);
            vm.prank(_bidder(i));
            tender.commitBid{value: BOND}(id, bytes32(i + 1));
        }
        vm.deal(_bidder(2), BOND);
        vm.prank(_bidder(2));
        vm.expectRevert(bytes("tender full"));
        tender.commitBid{value: BOND}(id, bytes32(uint256(3)));
    }

    /// At the cap, finalize stays far below a block's gas limit even with scrambled bids.
    function test_finalizeAtCapFitsInABlock() public {
        uint256 n = tender.MAX_BIDDERS();
        bytes32 id = tender.openTender(_terms(address(0xBEEF), n, address(0)));
        for (uint256 i; i < n; i++) {
            uint256 amt = (i * 7919) % 100003 + 1;
            vm.deal(_bidder(i), BOND);
            vm.prank(_bidder(i));
            tender.commitBid{value: BOND}(id, keccak256(abi.encode(id, _bidder(i), amt, bytes32(i))));
        }
        vm.warp(block.timestamp + 150);
        for (uint256 i; i < n; i++) {
            uint256 amt = (i * 7919) % 100003 + 1;
            vm.prank(_bidder(i));
            tender.revealBid(id, amt, bytes32(i));
        }
        vm.warp(block.timestamp + 100);
        uint256 g = gasleft();
        tender.finalize(id);
        uint256 used = g - gasleft();
        emit log_named_uint("finalize gas at MAX_BIDDERS", used);
        assertLt(used, 10_000_000);
    }

    // ── 2. a rejecting slash recipient cannot block the award ────────────────────

    function test_rejectingRecipientDoesNotBlockFinalize() public {
        RejectingRecipient bad = new RejectingRecipient();
        bytes32 id = tender.openTender(_terms(address(bad), 4, address(0)));
        address honest = _bidder(1);
        address silent = _bidder(2);
        vm.deal(honest, BOND);
        vm.deal(silent, BOND);
        vm.prank(honest);
        tender.commitBid{value: BOND}(id, keccak256(abi.encode(id, honest, uint256(50), bytes32("s"))));
        vm.prank(silent);
        tender.commitBid{value: BOND}(id, keccak256(abi.encode(id, silent, uint256(40), bytes32("t"))));
        vm.warp(block.timestamp + 150);
        vm.prank(honest);
        tender.revealBid(id, 50, bytes32("s"));
        vm.warp(block.timestamp + 100);

        IAwardMechanism.Award[] memory a = tender.finalize(id);
        assertEq(a.length, 1);
        assertEq(a[0].winner, honest);
        assertEq(tender.slashedOf(id), BOND);

        // The recipient's refusal only affects its own claim, which stays available.
        vm.expectRevert(bytes("bond return failed"));
        tender.claimSlashed(id);
        assertEq(tender.slashedOf(id), BOND);
    }

    // ── 3. ERC-20 bonds without return values ──────────────────────────────────

    function test_noReturnTokenBond() public {
        NoReturnToken usdt = new NoReturnToken();
        bytes32 id = tender.openTender(_terms(address(0xBEEF), 4, address(usdt)));
        address b = _bidder(1);
        usdt.mint(b, BOND);
        vm.prank(b);
        usdt.approve(address(tender), BOND);
        vm.prank(b);
        tender.commitBid(id, keccak256(abi.encode(id, b, uint256(50), bytes32("s"))));
        assertEq(usdt.balanceOf(address(tender)), BOND);

        vm.warp(block.timestamp + 150);
        vm.prank(b);
        tender.revealBid(id, 50, bytes32("s"));
        assertEq(usdt.balanceOf(b), BOND);
        assertEq(usdt.balanceOf(address(tender)), 0);
    }

    function test_bondAssetMustBeAContract() public {
        vm.expectRevert(bytes("bond asset is not a contract"));
        tender.openTender(_terms(address(0xBEEF), 4, address(0x1234)));
    }
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IAwardMechanism.sol";
import "../src/ISealedBidTender.sol";
import "../src/SealedBidTender.sol";
import "../src/mechanisms/FirstPriceAward.sol";
import "../src/mechanisms/VickreyAward.sol";
import "../src/mechanisms/UniformPriceAward.sol";
import "../src/mechanisms/PostedPriceAward.sol";

/// @dev Mirrors test/mechanisms.test.js and test/tender.test.js for anyone running Foundry.
contract SealedBidTenderTest is Test {
    FirstPriceAward fp;
    VickreyAward vk;
    UniformPriceAward up;
    SealedBidTender tender;

    address sink = address(0x4004);
    address requester = address(0x1001);
    address b1 = address(0x2001);
    address b2 = address(0x2002);
    address b3 = address(0x2003);
    address b4 = address(0x2004);
    uint256 constant BOND = 1 ether;
    uint256 constant RESERVE = 100;

    function setUp() public {
        fp = new FirstPriceAward();
        vk = new VickreyAward();
        up = new UniformPriceAward();
        tender = new SealedBidTender();
        vm.deal(b1, 10 ether);
        vm.deal(b2, 10 ether);
        vm.deal(b3, 10 ether);
        vm.deal(b4, 10 ether);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _bids(uint256 n) internal pure returns (IAwardMechanism.Bid[] memory b) {
        b = new IAwardMechanism.Bid[](n);
    }

    function _commit(bytes32 id, address who, uint256 amount, bytes32 salt) internal returns (bytes32 c) {
        c = keccak256(abi.encode(id, who, amount, salt));
        vm.prank(who);
        tender.commitBid{value: BOND}(id, c);
    }

    function _terms() internal view returns (ISealedBidTender.TenderTerms memory t) {
        t = ISealedBidTender.TenderTerms({
            targetRef: keccak256(abi.encode(block.chainid, address(0x6006), bytes32(uint256(1)))),
            mechanism: address(vk),
            reserve: RESERVE,
            units: 1,
            commitDeadline: uint64(block.timestamp + 100),
            revealDeadline: uint64(block.timestamp + 200),
            bond: BOND,
            bondAsset: address(0),
            slashRecipient: sink,
            maxBidders: 16,
            integrationProfile: AwardProfiles.PRICE_BINDING
        });
    }

    // ── mechanisms ─────────────────────────────────────────────────────────────

    function test_mechanismIds() public view {
        assertEq(fp.mechanismId(), bytes4(keccak256("award.first-price")));
        assertEq(vk.mechanismId(), bytes4(keccak256("award.vickrey")));
        assertEq(up.mechanismId(), bytes4(keccak256("award.uniform-price")));
        assertTrue(vk.supportsInterface(type(IAwardMechanism).interfaceId));
    }

    function test_vickrey_secondPrice() public view {
        IAwardMechanism.Bid[] memory b = _bids(3);
        b[0] = IAwardMechanism.Bid(b1, 70);
        b[1] = IAwardMechanism.Bid(b2, 40);
        b[2] = IAwardMechanism.Bid(b3, 55);
        IAwardMechanism.Award[] memory a = vk.award(b, RESERVE, 1);
        assertEq(a.length, 1);
        assertEq(a[0].winner, b2);
        assertEq(a[0].price, 55);
    }

    function test_vickrey_soloPaysReserve() public view {
        IAwardMechanism.Bid[] memory b = _bids(1);
        b[0] = IAwardMechanism.Bid(b1, 60);
        IAwardMechanism.Award[] memory a = vk.award(b, RESERVE, 1);
        assertEq(a[0].price, RESERVE);
    }

    function test_vickrey_secondAboveReserveCapped() public view {
        IAwardMechanism.Bid[] memory b = _bids(2);
        b[0] = IAwardMechanism.Bid(b1, 130);
        b[1] = IAwardMechanism.Bid(b2, 80);
        IAwardMechanism.Award[] memory a = vk.award(b, RESERVE, 1);
        assertEq(a[0].winner, b2);
        assertEq(a[0].price, RESERVE);
    }

    function test_noAwardAboveReserve() public view {
        IAwardMechanism.Bid[] memory b = _bids(2);
        b[0] = IAwardMechanism.Bid(b1, 120);
        b[1] = IAwardMechanism.Bid(b2, 150);
        assertEq(vk.award(b, RESERVE, 1).length, 0);
        assertEq(fp.award(b, RESERVE, 1).length, 0);
        assertEq(up.award(b, RESERVE, 1).length, 0);
    }

    function test_tieGoesToEarlierCommit() public view {
        IAwardMechanism.Bid[] memory b = _bids(3);
        b[0] = IAwardMechanism.Bid(b1, 50);
        b[1] = IAwardMechanism.Bid(b2, 50);
        b[2] = IAwardMechanism.Bid(b3, 50);
        assertEq(vk.award(b, RESERVE, 1)[0].winner, b1);
        assertEq(fp.award(b, RESERVE, 1)[0].winner, b1);
        assertEq(up.award(b, RESERVE, 1)[0].winner, b1);
    }

    function test_vickrey_rejectsMultiUnit() public {
        IAwardMechanism.Bid[] memory b = _bids(1);
        b[0] = IAwardMechanism.Bid(b1, 10);
        vm.expectRevert(bytes("vickrey: units must be 1"));
        vk.award(b, RESERVE, 2);
    }

    function test_uniformPrice_threeUnits() public view {
        IAwardMechanism.Bid[] memory b = _bids(5);
        b[0] = IAwardMechanism.Bid(b1, 90);
        b[1] = IAwardMechanism.Bid(b2, 30);
        b[2] = IAwardMechanism.Bid(b3, 60);
        b[3] = IAwardMechanism.Bid(b4, 45);
        b[4] = IAwardMechanism.Bid(address(0x2005), 75);
        IAwardMechanism.Award[] memory a = up.award(b, RESERVE, 3);
        assertEq(a.length, 3);
        assertEq(a[0].winner, b2);
        assertEq(a[1].winner, b4);
        assertEq(a[2].winner, b3);
        for (uint256 i; i < 3; i++) assertEq(a[i].price, 75);
    }

    /// @dev Monotonicity (spec condition 5), fuzzed: lowering a winner's bid keeps it a winner.
    function testFuzz_monotonicity(uint8 x, uint8 y, uint8 z, uint8 lower) public view {
        IAwardMechanism.Bid[] memory b = _bids(3);
        b[0] = IAwardMechanism.Bid(b1, x);
        b[1] = IAwardMechanism.Bid(b2, y);
        b[2] = IAwardMechanism.Bid(b3, z);
        IAwardMechanism.Award[] memory a = vk.award(b, 200, 1);
        if (a.length == 0) return;
        uint256 idx = a[0].winner == b1 ? 0 : a[0].winner == b2 ? 1 : 2;
        if (lower >= b[idx].amount) return;
        b[idx].amount = lower;
        IAwardMechanism.Award[] memory a2 = vk.award(b, 200, 1);
        assertEq(a2[0].winner, a[0].winner);
    }

    /// @dev Vickrey truthfulness, fuzzed: deviating from true cost never raises utility.
    function testFuzz_vickreyTruthful(uint8 c1, uint8 c2, uint8 c3, uint8 dev) public view {
        IAwardMechanism.Bid[] memory truthful = _bids(3);
        truthful[0] = IAwardMechanism.Bid(b1, c1);
        truthful[1] = IAwardMechanism.Bid(b2, c2);
        truthful[2] = IAwardMechanism.Bid(b3, c3);
        int256 uT = _util(vk.award(truthful, 200, 1), b1, c1);
        truthful[0].amount = dev;
        int256 uD = _util(vk.award(truthful, 200, 1), b1, c1);
        assertGe(uT, uD);
    }

    function _util(IAwardMechanism.Award[] memory a, address who, uint256 cost) internal pure returns (int256) {
        for (uint256 i; i < a.length; i++) {
            if (a[i].winner == who) return int256(a[i].price) - int256(cost);
        }
        return 0;
    }

    // ── tender lifecycle ───────────────────────────────────────────────────────

    function test_lifecycle() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        vm.prank(requester);
        bytes32 id = tender.openTender(t);
        assertEq(uint256(tender.phaseOf(id)), uint256(ISealedBidTender.Phase.Commit));
        assertEq(tender.requesterOf(id), requester);

        _commit(id, b2, 60, bytes32(uint256(2)));
        _commit(id, b3, 40, bytes32(uint256(3)));
        _commit(id, b4, 70, bytes32(uint256(4))); // will not reveal
        assertEq(address(tender).balance, 3 * BOND);

        vm.prank(b2);
        vm.expectRevert(bytes("already committed"));
        tender.commitBid{value: BOND}(id, bytes32(uint256(1)));

        vm.warp(t.commitDeadline + 1);
        uint256 before = b2.balance;
        vm.prank(b2);
        tender.revealBid(id, 60, bytes32(uint256(2)));
        assertEq(b2.balance, before + BOND);
        vm.prank(b3);
        tender.revealBid(id, 40, bytes32(uint256(3)));

        vm.prank(b2);
        vm.expectRevert(bytes("already revealed"));
        tender.revealBid(id, 60, bytes32(uint256(2)));

        vm.expectRevert(bytes("reveal window still open"));
        tender.finalize(id);

        vm.warp(t.revealDeadline + 1);
        uint256 sinkBefore = sink.balance;
        IAwardMechanism.Award[] memory a = tender.finalize(id);
        assertEq(a.length, 1);
        assertEq(a[0].winner, b3);
        assertEq(a[0].price, 60);
        assertEq(tender.slashedOf(id), BOND);
        assertEq(tender.claimSlashed(id), BOND);
        assertEq(sink.balance, sinkBefore + BOND);
        assertEq(address(tender).balance, 0);
        vm.expectRevert(bytes("nothing to claim"));
        tender.claimSlashed(id);
        assertEq(uint256(tender.phaseOf(id)), uint256(ISealedBidTender.Phase.Awarded));
        assertEq(tender.awardOf(id).length, 1);

        vm.expectRevert(bytes("already finalized"));
        tender.finalize(id);
    }

    function test_void_whenNobodyUnderReserve() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        t.reserve = 50;
        vm.prank(requester);
        bytes32 id = tender.openTender(t);
        _commit(id, b2, 80, bytes32(uint256(2)));
        vm.warp(t.commitDeadline + 1);
        vm.prank(b2);
        tender.revealBid(id, 80, bytes32(uint256(2)));
        vm.warp(t.revealDeadline + 1);
        assertEq(tender.finalize(id).length, 0);
        assertEq(uint256(tender.phaseOf(id)), uint256(ISealedBidTender.Phase.Void));
    }

    function test_openTender_validation() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        t.reserve = 0;
        vm.expectRevert(bytes("reserve must be > 0"));
        tender.openTender(t);

        t = _terms();
        t.revealDeadline = t.commitDeadline;
        vm.expectRevert(bytes("reveal must follow commit"));
        tender.openTender(t);

        t = _terms();
        t.mechanism = sink;
        vm.expectRevert();
        tender.openTender(t);

        t = _terms();
        t.slashRecipient = address(0);
        vm.expectRevert(bytes("slash recipient required"));
        tender.openTender(t);

        t = _terms();
        t.slashRecipient = requester;
        vm.prank(requester);
        vm.expectRevert(bytes("requester cannot receive slashes"));
        tender.openTender(t);
    }

    function test_targetRefOf() public view {
        bytes32 expected = keccak256(abi.encode(uint256(1), address(0x6006), bytes32(uint256(42))));
        assertEq(uint256(tender.targetRefOf(1, address(0x6006), bytes32(uint256(42)))), uint256(expected));
    }

    function test_revealWindowEnforced() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        vm.prank(requester);
        bytes32 id = tender.openTender(t);
        _commit(id, b2, 60, bytes32(uint256(2)));

        vm.prank(b2);
        vm.expectRevert(bytes("commit window still open"));
        tender.revealBid(id, 60, bytes32(uint256(2)));

        vm.warp(t.revealDeadline + 1);
        vm.prank(b2);
        vm.expectRevert(bytes("reveal window closed"));
        tender.revealBid(id, 60, bytes32(uint256(2)));
    }

    // ── integration profiles and posted price ───────────────────────────────────

    function test_postedPrice_earliestAcceptancesWinAtReserve() public {
        PostedPriceAward pp = new PostedPriceAward();
        IAwardMechanism.Bid[] memory b = _bids(4);
        b[0] = IAwardMechanism.Bid(b1, 150); // declines (above reserve)
        b[1] = IAwardMechanism.Bid(b2, 100);
        b[2] = IAwardMechanism.Bid(b3, 10); // a low bid is just an acceptance: it does not jump the queue
        b[3] = IAwardMechanism.Bid(b4, 100);
        IAwardMechanism.Award[] memory a = pp.award(b, RESERVE, 2);
        assertEq(a.length, 2);
        assertEq(a[0].winner, b2);
        assertEq(a[1].winner, b3);
        assertEq(a[0].price, RESERVE);
        assertEq(a[1].price, RESERVE);
    }

    /// Under posted price, accepting iff cost <= reserve is dominant, at any commit position.
    function testFuzz_postedPriceAcceptance(uint8 cost, uint8 dev, uint8 other, bool first) public {
        PostedPriceAward pp = new PostedPriceAward();
        uint256 r = 128;
        uint256 truthful = cost <= r ? r : 255;
        IAwardMechanism.Bid[] memory b = _bids(2);
        uint256 me = first ? 0 : 1;
        b[1 - me] = IAwardMechanism.Bid(b2, other);
        b[me] = IAwardMechanism.Bid(b1, truthful);
        int256 uT = _util(pp.award(b, r, 1), b1, cost);
        b[me] = IAwardMechanism.Bid(b1, dev);
        int256 uD = _util(pp.award(b, r, 1), b1, cost);
        assertGe(uT, uD);
    }

    function test_allocationOnlyRequiresPostedPrice() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        t.integrationProfile = AwardProfiles.ALLOCATION_ONLY;
        vm.expectRevert(bytes("allocation-only requires award.posted-price"));
        tender.openTender(t);
        t.mechanism = address(new PostedPriceAward());
        tender.openTender(t);
        t.integrationProfile = bytes4(0xdeadbeef);
        vm.expectRevert(bytes("unknown integration profile"));
        tender.openTender(t);
    }

    /// Ties follow commit order even when the earlier committer reveals last.
    function test_tieFollowsCommitOrderNotRevealOrder() public {
        ISealedBidTender.TenderTerms memory t = _terms();
        vm.prank(requester);
        bytes32 id = tender.openTender(t);
        _commit(id, b2, 50, bytes32(uint256(2)));
        _commit(id, b3, 50, bytes32(uint256(3)));
        vm.warp(t.commitDeadline + 1);
        vm.prank(b3);
        tender.revealBid(id, 50, bytes32(uint256(3)));
        vm.prank(b2);
        tender.revealBid(id, 50, bytes32(uint256(2)));
        vm.warp(t.revealDeadline + 1);
        assertEq(tender.finalize(id)[0].winner, b2);
    }
}

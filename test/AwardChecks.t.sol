// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SealedBidTender.sol";
import "../src/mechanisms/BaseAwardMechanism.sol";
import "../src/mechanisms/VickreyAward.sol";
import "../src/mechanisms/FirstPriceAward.sol";

/// @dev Faulty mechanisms. Each breaks one condition the tender must enforce whatever the
///      pricing rule. Raised by Revinand on the Ethereum Magicians thread (post #15).
contract GhostWinner is BaseAwardMechanism {
    function mechanismId() external pure returns (bytes4) { return bytes4(keccak256("test.ghost")); }
    function award(Bid[] calldata, uint256 reserve, uint256) external pure returns (Award[] memory out) {
        out = new Award[](1);
        out[0] = Award(address(0xBEEF), reserve); // never committed, never revealed
    }
}

contract OverReserveWinner is BaseAwardMechanism {
    function mechanismId() external pure returns (bytes4) { return bytes4(keccak256("test.over-reserve")); }
    function award(Bid[] calldata bids, uint256 reserve, uint256) external pure returns (Award[] memory out) {
        uint256 hi;
        for (uint256 i = 1; i < bids.length; i++) if (bids[i].amount > bids[hi].amount) hi = i;
        out = new Award[](1);
        out[0] = Award(bids[hi].bidder, reserve); // the highest ask, above the reserve
    }
}

contract Underpay is BaseAwardMechanism {
    function mechanismId() external pure returns (bytes4) { return bytes4(keccak256("test.underpay")); }
    function award(Bid[] calldata bids, uint256, uint256) external pure returns (Award[] memory out) {
        out = new Award[](1);
        out[0] = Award(bids[0].bidder, bids[0].amount - 1); // pays less than the winner asked
    }
}

contract AwardChecksTest is Test {
    SealedBidTender tender;
    uint256 constant BOND = 1 ether;
    uint256 constant RESERVE = 100;
    address constant SINK = address(0xdEaD);

    function setUp() public {
        tender = new SealedBidTender();
    }

    function _open(address mech) internal returns (bytes32) {
        return tender.openTender(
            ISealedBidTender.TenderTerms({
                targetRef: bytes32(uint256(1)),
                mechanism: mech,
                reserve: RESERVE,
                units: 1,
                commitDeadline: uint64(block.timestamp + 100),
                revealDeadline: uint64(block.timestamp + 200),
                bond: BOND,
                bondAsset: address(0),
                slashRecipient: SINK,
                maxBidders: 8,
                integrationProfile: AwardProfiles.PRICE_BINDING
            })
        );
    }

    /// Two bidders, 60 and 140; a third commits 30 but never reveals.
    function _run(address mech) internal returns (bytes32 id) {
        id = _open(mech);
        address[3] memory who = [address(0xA1), address(0xA2), address(0xA3)];
        uint256[3] memory amt = [uint256(60), 140, 30];
        for (uint256 i; i < 3; i++) {
            vm.deal(who[i], BOND);
            vm.prank(who[i]);
            tender.commitBid{value: BOND}(id, keccak256(abi.encode(id, who[i], amt[i], bytes32(i))));
        }
        vm.warp(block.timestamp + 150);
        for (uint256 i; i < 2; i++) {
            vm.prank(who[i]);
            tender.revealBid(id, amt[i], bytes32(i));
        }
        vm.warp(block.timestamp + 100);
    }

    function test_rejectsWinnerWhoNeverRevealed() public {
        bytes32 id = _run(address(new GhostWinner()));
        vm.expectRevert(bytes("winner did not reveal"));
        tender.finalize(id);
    }

    function test_rejectsWinnerAboveReserve() public {
        bytes32 id = _run(address(new OverReserveWinner()));
        vm.expectRevert(bytes("winner bid above reserve"));
        tender.finalize(id);
    }

    function test_rejectsPriceBelowWinnersBid() public {
        bytes32 id = _run(address(new Underpay()));
        vm.expectRevert(bytes("price below winner's bid"));
        tender.finalize(id);
    }

    function test_normativeRulePasses() public {
        bytes32 id = _run(address(new VickreyAward()));
        IAwardMechanism.Award[] memory a = tender.finalize(id);
        assertEq(a[0].winner, address(0xA1));
        assertEq(a[0].price, RESERVE); // only other revealed bid (140) is above the reserve
    }

    /// The mechanism is pinned by code hash at open. Swapping the code at the same address,
    /// as a metamorphic contract could, makes finalize revert instead of using the new rule.
    function test_mechanismCodeChangeReverts() public {
        VickreyAward vk = new VickreyAward();
        bytes32 id = _run(address(vk));
        assertEq(tender.mechanismCodehashOf(id), address(vk).codehash);
        vm.etch(address(vk), address(new FirstPriceAward()).code);
        vm.expectRevert(bytes("mechanism code changed"));
        tender.finalize(id);
    }
}

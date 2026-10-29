// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "../../src/ISealedBidTender.sol";
import "../../src/SealedBidTender.sol";
import "./MockTaskToken.sol";

interface IAwardMintExample {
    function tender() external view returns (ISealedBidTender);
    function tenderOfToken(address target, uint256 tokenId) external view returns (bytes32);
}

/// @dev Test-only provider identity owning one exclusive slot. All requests in this
///      example conflict, irrespective of time. This does not establish that an operator
///      has only one identity or that a physical service will be delivered.
contract CapacityProvider {
    address public immutable controller;
    ISealedBidTender public immutable tender;
    bytes32 public reservedTender;
    bytes32 public targetRef;
    bytes32 public contentHash;
    address public activeTarget;
    uint256 public activeToken;
    bool public consumed;

    constructor(ISealedBidTender tender_, address controller_) {
        tender = tender_;
        controller = controller_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "only controller");
        _;
    }

    function commit(bytes32 id, bytes32 commitment) external payable onlyController {
        require(reservedTender == bytes32(0), "capacity reserved");
        ISealedBidTender.TenderTerms memory terms = tender.termsOf(id);
        require(terms.units == 1 && terms.contentHash != bytes32(0), "unsupported terms");
        // The core sees this contract as the bidder. It cannot sign a direct EOA transaction
        // bypassing admission. A failure in commitBid rolls back the reservation as well.
        reservedTender = id;
        targetRef = terms.targetRef;
        contentHash = terms.contentHash;
        tender.commitBid{value: msg.value}(id, commitment);
    }

    function reveal(bytes32 id, uint256 amount, bytes32 salt) external onlyController {
        require(id == reservedTender, "other reservation");
        tender.revealBid(id, amount, salt);
    }

    function releaseUnawarded() external {
        require(reservedTender != bytes32(0) && !consumed, "no releasable reservation");
        ISealedBidTender.Phase phase = tender.phaseOf(reservedTender);
        require(phase == ISealedBidTender.Phase.Awarded || phase == ISealedBidTender.Phase.Void, "not final");
        IAwardMechanism.Award[] memory awards = tender.awardOf(reservedTender);
        for (uint256 i; i < awards.length; i++) {
            require(awards[i].winner != address(this), "winner retains capacity");
        }
        _clear();
    }

    function consume(bytes32 id, uint256 tokenId, bytes32 hash) external returns (bytes4) {
        require(id == reservedTender && id != bytes32(0) && !consumed, "wrong reservation");
        require(targetRef == keccak256(abi.encode(block.chainid, msg.sender, bytes32(tokenId))), "wrong target");
        require(hash == contentHash, "wrong content");
        IAwardMechanism.Award[] memory awards = tender.awardOf(id);
        require(awards.length == 1 && awards[0].winner == address(this), "not winner");
        consumed = true;
        activeTarget = msg.sender;
        activeToken = tokenId;
        return this.consume.selector;
    }

    function submit(bytes32 resultHash) external onlyController returns (uint256) {
        require(consumed, "not executed");
        return MockTaskToken(activeTarget).submitFulfillment(activeToken, resultHash);
    }

    function releaseCompleted() external {
        require(consumed, "not executed");
        require(MockTaskToken(activeTarget).completionsOf(activeToken) == 1, "work not complete");
        _clear();
    }

    function _clear() private {
        reservedTender = bytes32(0);
        targetRef = bytes32(0);
        contentHash = bytes32(0);
        activeTarget = address(0);
        activeToken = 0;
        consumed = false;
    }

    receive() external payable {}
}

/// @dev Admission must cover the actual tender entry point: a target-side gate alone
///      would still allow an unreserved outsider to win and make settlement revert.
contract CapacityAdmittedTender is SealedBidTender {
    address public immutable administrator = msg.sender;
    mapping(address => bool) public admitted;

    function admit(address provider) external {
        require(msg.sender == administrator, "only administrator");
        require(address(CapacityProvider(payable(provider)).tender()) == address(this), "other tender contract");
        admitted[provider] = true; // append-only; no revocation after bidding
    }

    function commitBid(bytes32 id, bytes32 commitment) public payable override {
        require(admitted[msg.sender], "provider not admitted");
        CapacityProvider provider = CapacityProvider(payable(msg.sender));
        TenderTerms memory terms = this.termsOf(id);
        require(provider.reservedTender() == id, "reservation required");
        require(provider.targetRef() == terms.targetRef && provider.contentHash() == terms.contentHash, "reservation mismatch");
        super.commitBid(id, commitment);
    }
}

abstract contract CapacityTaskBase is MockTaskToken {
    function _award(uint256 tokenId) internal view returns (bytes32 id, address winner) {
        IAwardMintExample adapter = IAwardMintExample(msg.sender);
        id = adapter.tenderOfToken(address(this), tokenId);
        IAwardMechanism.Award[] memory awards = adapter.tender().awardOf(id);
        require(awards.length == 1, "one award required");
        winner = awards[0].winner;
    }
}

/// @dev Negative control: no pre-bid reservation; availability is checked only at mint.
contract LateCapacityTask is CapacityTaskBase {
    mapping(address => bool) public busy;

    function mint(uint256 tokenId, address updater, address verifier, uint256 reward, uint64 count, bytes32 hash)
        public payable override
    {
        (, address winner) = _award(tokenId);
        require(!busy[winner], "capacity unavailable at execution");
        busy[winner] = true;
        super.mint(tokenId, updater, verifier, reward, count, hash);
    }
}

/// @dev Positive control: deployment admits only known slot-owning identities and consumes
///      an existing exclusive reservation atomically. No capacity registry or identity API
///      is proposed for ERC-8469 by these test-only mocks.
contract ReservedCapacityTask is CapacityTaskBase {
    mapping(address => bool) public admitted;

    constructor(address[] memory providers) {
        for (uint256 i; i < providers.length; i++) admitted[providers[i]] = true;
    }

    function mint(uint256 tokenId, address updater, address verifier, uint256 reward, uint64 count, bytes32 hash)
        public payable override
    {
        (bytes32 id, address winner) = _award(tokenId);
        require(admitted[winner], "provider not admitted");
        require(count == 1, "one slot only");
        require(CapacityProvider(payable(winner)).consume(id, tokenId, hash) == CapacityProvider.consume.selector, "not reserved");
        super.mint(tokenId, updater, verifier, reward, count, hash);
    }
}

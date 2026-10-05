// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "../ISealedBidTender.sol";
import "../IAwardMechanism.sol";

/// @dev The parts of ERC-8414 this adapter reads, as given in the ERC-8414 draft
///      (Ethereum Magicians thread 29597). Only the functions used here are declared.
interface ITaskVerifier {
    function verifyFulfillment(
        address taskContract,
        uint256 tokenId,
        uint256 submissionId,
        address fulfiller,
        bytes32 resultHash,
        bytes calldata proof
    ) external returns (bool);
}

interface ITaskTokenAuthority {
    function updateAuthorityOf(uint256 tokenId) external view returns (address);
}

interface ITaskTenderTerms {
    struct TenderTerms {
        address asset;
        uint256 rewardPerCompletion;
        uint64 maxCompletions;
        uint64 submitBy;
        uint64 settleBy;
        uint64 epochLength;
        uint64 maxCompletionsPerEpoch;
        uint64 judgmentWindow;
    }

    function tenderTermsOf(uint256 tokenId) external view returns (TenderTerms memory);
}

/// @title AwardGatedVerifier
/// @notice An ERC-8414 `ITaskVerifier` that settles a submission only when both hold:
///         (1) an inner verifier accepts the work, and
///         (2) the fulfiller of record is a winner of the sealed-bid tender bound to the task.
/// @dev Placed in an ERC-8414 task's acceptance-authority slot, this makes the task
///      machine-settled with award-gated eligibility. It follows the draft ERC's authority
///      boundary: the award only narrows who may be paid; it never changes the task's
///      reward, which stays the immutable `rewardPerCompletion`.
///
///      Because the reward is fixed, this is an allocation-only integration, and the bound
///      tender MUST use award.posted-price. A bid-ranking rule on a fixed reward is not
///      incentive compatible: every bidder below the reward would bid the minimum and the
///      award would go to whoever committed first. For price discovery on 8414 use
///      AwardThenMint, which mints the token with rewardPerCompletion = Award.price.
///
///      Binding rules, all checked once at `bind` and fixed thereafter:
///        - only the task token's update authority may bind, and only once per token;
///        - the tender's `targetRef` MUST equal keccak256(abi.encode(chainid, taskContract, bytes32(tokenId)));
///        - the tender's requester MUST be that same update authority, so nobody can bind a
///          token to a tender they opened and won themselves;
///        - the tender MUST be allocation-only and use award.posted-price;
///        - the tender's reserve MUST equal the task's `rewardPerCompletion`, so the posted
///          price is the reward;
///        - the tender's `units` MUST NOT exceed `maxCompletions` when that is bounded.
///
///      A `false` return is not a rejection under ERC-8414: the submission stays pending and
///      may be settled later. So a submission made before the award is final simply waits.
contract AwardGatedVerifier is ITaskVerifier {
    struct Binding {
        address tender;
        bytes32 tenderId;
        address inner;
    }

    /// taskContract => tokenId => binding
    mapping(address => mapping(uint256 => Binding)) public bindingOf;

    event Bound(
        address indexed taskContract,
        uint256 indexed tokenId,
        address tender,
        bytes32 indexed tenderId,
        address inner
    );

    bytes4 private constant ITASK_VERIFIER_ID = 0x9977db15; // as published with ERC-8414

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ITASK_VERIFIER_ID || id == type(ITaskVerifier).interfaceId || id == 0x01ffc9a7;
    }

    /// @notice Canonical target reference for an ERC-8414 token, per the draft ERC.
    function targetRefFor(address taskContract, uint256 tokenId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, taskContract, bytes32(tokenId)));
    }

    /// @notice Bind an ERC-8414 task token to a tender and an inner work verifier. Once only.
    function bind(address taskContract, uint256 tokenId, address tender, bytes32 tenderId, address inner) external {
        require(bindingOf[taskContract][tokenId].tender == address(0), "already bound");
        require(tender != address(0) && inner != address(0), "zero address");

        address authority = ITaskTokenAuthority(taskContract).updateAuthorityOf(tokenId);
        require(msg.sender == authority, "only update authority");

        ISealedBidTender t = ISealedBidTender(tender);
        ISealedBidTender.TenderTerms memory terms = t.termsOf(tenderId);
        require(terms.targetRef == targetRefFor(taskContract, tokenId), "tender targets another task");
        require(t.requesterOf(tenderId) == authority, "tender not opened by task authority");
        require(terms.integrationProfile == AwardProfiles.ALLOCATION_ONLY, "tender must be allocation-only");
        require(
            IAwardMechanism(terms.mechanism).mechanismId() == AwardProfiles.POSTED_PRICE,
            "tender must use award.posted-price"
        );

        ITaskTenderTerms.TenderTerms memory task = ITaskTenderTerms(taskContract).tenderTermsOf(tokenId);
        require(terms.reserve == task.rewardPerCompletion, "reserve must equal reward");
        require(task.maxCompletions == 0 || terms.units <= task.maxCompletions, "more units than completions");

        bindingOf[taskContract][tokenId] = Binding({tender: tender, tenderId: tenderId, inner: inner});
        emit Bound(taskContract, tokenId, tender, tenderId, inner);
    }

    /// @notice Whether `who` is a winner of the tender bound to this task.
    function isWinner(address taskContract, uint256 tokenId, address who) public view returns (bool) {
        Binding memory b = bindingOf[taskContract][tokenId];
        if (b.tender == address(0)) return false;
        IAwardMechanism.Award[] memory awards = ISealedBidTender(b.tender).awardOf(b.tenderId);
        for (uint256 i = 0; i < awards.length; i++) {
            if (awards[i].winner == who) return true;
        }
        return false;
    }

    /// @inheritdoc ITaskVerifier
    function verifyFulfillment(
        address taskContract,
        uint256 tokenId,
        uint256 submissionId,
        address fulfiller,
        bytes32 resultHash,
        bytes calldata proof
    ) external returns (bool) {
        // ERC-8414 calls this with taskContract == msg.sender; refuse anything else so the
        // verifier cannot be driven by a contract pretending to be the task.
        if (taskContract != msg.sender) return false;
        if (!isWinner(taskContract, tokenId, fulfiller)) return false;
        Binding memory b = bindingOf[taskContract][tokenId];
        return ITaskVerifier(b.inner).verifyFulfillment(taskContract, tokenId, submissionId, fulfiller, resultHash, proof);
    }
}

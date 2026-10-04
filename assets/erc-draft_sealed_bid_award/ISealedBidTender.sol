// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "./IAwardMechanism.sol";

/// @title ISealedBidTender
/// @notice Sealed-bid tender lifecycle: commit, reveal, award. Holds bidder bonds only;
///         never holds the task reward.
interface ISealedBidTender {
    enum Phase {
        None,
        Commit,
        Reveal,
        Awarded,
        Void
    }

    struct TenderTerms {
        bytes32 targetRef; // keccak256(abi.encode(chainId, targetContract, targetId)); see the ERC
        address mechanism; // IAwardMechanism
        uint256 reserve; // MUST be > 0
        uint256 units; // MUST be >= 1
        uint64 commitDeadline; // commits accepted while block.timestamp <= commitDeadline
        uint64 revealDeadline; // reveals accepted while commitDeadline < block.timestamp <= revealDeadline
        uint256 bond; // escrowed per commit
        address bondAsset; // address(0) for the chain's native asset, else an ERC-20
        address slashRecipient; // where slashed bonds go; MUST be non-zero when bond > 0
        uint256 maxBidders; // commitments accepted per tender; MUST be >= 1 and <= the implementation's limit
    }

    event TenderOpened(
        bytes32 indexed tenderId,
        bytes32 indexed targetRef,
        address indexed requester,
        address mechanism,
        uint256 reserve,
        uint256 units,
        uint64 commitDeadline,
        uint64 revealDeadline
    );
    event BidCommitted(bytes32 indexed tenderId, address indexed bidder, bytes32 commitment);
    event BidRevealed(bytes32 indexed tenderId, address indexed bidder, uint256 amount);
    event BidSlashed(bytes32 indexed tenderId, address indexed bidder, uint256 bond);
    event TenderAwarded(bytes32 indexed tenderId, address indexed winner, uint256 price, bytes4 mechanismId);
    event TenderVoid(bytes32 indexed tenderId);
    event SlashClaimed(bytes32 indexed tenderId, address indexed recipient, uint256 amount);

    function openTender(TenderTerms calldata terms) external returns (bytes32 tenderId);
    function commitBid(bytes32 tenderId, bytes32 commitment) external payable;
    function revealBid(bytes32 tenderId, uint256 amount, bytes32 salt) external;
    function finalize(bytes32 tenderId) external returns (IAwardMechanism.Award[] memory);
    /// @notice Pay accumulated slashed bonds to the tender's slashRecipient. Permissionless.
    ///         Kept separate from finalize so a recipient that rejects payment cannot block the award.
    function claimSlashed(bytes32 tenderId) external returns (uint256 amount);

    function termsOf(bytes32 tenderId) external view returns (TenderTerms memory);
    function requesterOf(bytes32 tenderId) external view returns (address);
    function phaseOf(bytes32 tenderId) external view returns (Phase);
    function awardOf(bytes32 tenderId) external view returns (IAwardMechanism.Award[] memory);
    function slashedOf(bytes32 tenderId) external view returns (uint256);
}

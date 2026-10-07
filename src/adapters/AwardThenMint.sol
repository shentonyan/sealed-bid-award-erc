// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "../ISealedBidTender.sol";
import "../IAwardMechanism.sol";

/// @dev ERC-8414 does not standardise minting, so this is the minimal mint surface the adapter
///      needs, matching the test mock. A deployment would adapt it to its task contract.
///      The adapter relies on one property of the task contract: an id whose top 160 bits are
///      an address can be minted only by that address. That reservation is what makes
///      execution impossible to pre-empt (see `AwardThenMint`).
interface ITaskMinter {
    function mint(uint256 tokenId, address updateAuthority, address acceptanceAuthority, uint256 reward, uint64 maxCompletions)
        external
        payable;
}

interface ITaskVerifierGated {
    function verifyFulfillment(
        address taskContract,
        uint256 tokenId,
        uint256 submissionId,
        address fulfiller,
        bytes32 resultHash,
        bytes calldata proof
    ) external returns (bool);
}

/// @title AwardThenMint
/// @notice Price-binding integration with ERC-8414: one settle transition finalizes the tender,
///         mints the task token with rewardPerCompletion = Award.price, and refunds the rest.
/// @dev The draft ERC's incentive claims (for example truthful bidding under award.vickrey) hold
///      only if the integration is payment-binding (it pays Award.price) and execution-binding
///      (every non-empty award can be executed by anyone, and no one can withhold, pre-empt or
///      block that execution). The terms are chugarchugarr's, from the Ethereum Magicians thread
///      (posts #7 and #10). This adapter gives both:
///        - the requester escrows the reserve when the tender opens, so the money to pay any
///          price up to the reserve is already committed;
///        - `settle` is permissionless, so once the tender is awarded anyone (typically the
///          winner) can force the mint at the award price and fund it from the escrow;
///        - the unused escrow, reserve minus price, is credited to the requester and claimed
///          separately, so a requester that rejects payment cannot block the mint.
///      The minted token's acceptance authority is this contract, which settles a submission
///      only if the fulfiller is the winner and an inner work verifier accepts the work.
///        - the token id is reserved when the tender opens: it lies in this adapter's minter
///          namespace, (address(this) << 96) | nonce, so no one else can mint it first and make
///          settle revert. An earlier version used uint256(taskHash), which anyone could mint.
///      The target reference is the canonical one for the id that will be minted,
///      keccak256(abi.encode(chainId, taskContract, bytes32(tokenId))). The task hash is recorded
///      in the job and in JobOpened as the content the requester committed to.
contract AwardThenMint is ITaskVerifierGated {
    struct Job {
        address requester;
        address taskContract;
        bytes32 taskHash;
        address inner;
        uint256 tokenId;
        uint256 escrow;
        address winner;
        bool settled;
    }

    ISealedBidTender public immutable tender;
    mapping(bytes32 => Job) public jobOf; // tenderId => job
    mapping(address => mapping(uint256 => bytes32)) public tenderOfToken; // taskContract => tokenId => tenderId
    mapping(address => uint256) public refundOf;
    uint96 public nonce;

    uint256 private _lock = 1;

    event JobOpened(bytes32 indexed tenderId, address indexed requester, address indexed taskContract, uint256 tokenId, bytes32 taskHash, uint256 escrow);
    event JobSettled(bytes32 indexed tenderId, address winner, uint256 price, uint256 refund);
    event RefundClaimed(address indexed requester, uint256 amount);

    modifier nonReentrant() {
        require(_lock == 1, "reentrant");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(ISealedBidTender tender_) {
        tender = tender_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x9977db15 || id == 0x01ffc9a7; // ERC-8414 ITaskVerifier, ERC-165
    }

    function targetRefFor(address taskContract, uint256 tokenId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, taskContract, bytes32(tokenId)));
    }

    /// @notice The id the next job will mint. Only this adapter can mint ids in its namespace.
    function nextTokenId() public view returns (uint256) {
        return (uint256(uint160(address(this))) << 96) | uint256(nonce);
    }

    /// @notice Open a price-binding tender for a task that will be minted after the award.
    ///         msg.value is the reserve and is escrowed here until settlement.
    function open(
        address taskContract,
        bytes32 taskHash,
        address inner,
        address mechanism,
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint256 bond,
        address slashRecipient,
        uint256 maxBidders
    ) external payable nonReentrant returns (bytes32 tenderId) {
        require(msg.value > 0, "escrow the reserve");
        require(inner != address(0) && taskContract != address(0), "zero address");
        require(slashRecipient != msg.sender, "requester cannot receive slashes");
        uint256 tokenId = nextTokenId();
        nonce++;

        tenderId = tender.openTender(
            ISealedBidTender.TenderTerms({
                targetRef: targetRefFor(taskContract, tokenId),
                mechanism: mechanism,
                reserve: msg.value,
                units: 1,
                commitDeadline: commitDeadline,
                revealDeadline: revealDeadline,
                bond: bond,
                bondAsset: address(0),
                slashRecipient: slashRecipient,
                maxBidders: maxBidders,
                integrationProfile: AwardProfiles.PRICE_BINDING
            })
        );
        jobOf[tenderId] = Job({
            requester: msg.sender,
            taskContract: taskContract,
            taskHash: taskHash,
            inner: inner,
            tokenId: tokenId,
            escrow: msg.value,
            winner: address(0),
            settled: false
        });
        tenderOfToken[taskContract][tokenId] = tenderId;
        emit JobOpened(tenderId, msg.sender, taskContract, tokenId, taskHash, msg.value);
    }

    /// @notice Execute the award. Permissionless: the requester cannot withhold execution.
    function settle(bytes32 tenderId) external nonReentrant {
        Job storage j = jobOf[tenderId];
        require(j.requester != address(0), "unknown job");
        require(!j.settled, "already settled");

        ISealedBidTender.Phase phase = tender.phaseOf(tenderId);
        if (phase == ISealedBidTender.Phase.Commit || phase == ISealedBidTender.Phase.Reveal) {
            tender.finalize(tenderId); // reverts while the reveal window is open
            phase = tender.phaseOf(tenderId);
        }
        j.settled = true;

        uint256 price;
        if (phase == ISealedBidTender.Phase.Awarded) {
            IAwardMechanism.Award[] memory a = tender.awardOf(tenderId);
            price = a[0].price; // the tender guarantees price <= reserve == escrow
            j.winner = a[0].winner;
            ITaskMinter(j.taskContract).mint{value: price}(
                j.tokenId, j.requester, address(this), price, 1
            );
        }
        uint256 refund = j.escrow - price;
        refundOf[j.requester] += refund;
        emit JobSettled(tenderId, j.winner, price, refund);
    }

    function claimRefund() external nonReentrant returns (uint256 amount) {
        amount = refundOf[msg.sender];
        require(amount > 0, "nothing to claim");
        refundOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");
        emit RefundClaimed(msg.sender, amount);
    }

    /// @notice ERC-8414 verifier for tokens minted here: only the winner, and only for work the
    ///         inner verifier accepts.
    function verifyFulfillment(
        address taskContract,
        uint256 tokenId,
        uint256 submissionId,
        address fulfiller,
        bytes32 resultHash,
        bytes calldata proof
    ) external returns (bool) {
        if (taskContract != msg.sender) return false;
        bytes32 tenderId = tenderOfToken[taskContract][tokenId];
        if (tenderId == bytes32(0)) return false;
        Job storage j = jobOf[tenderId];
        if (!j.settled || j.winner == address(0) || fulfiller != j.winner) return false;
        return ITaskVerifierGated(j.inner).verifyFulfillment(taskContract, tokenId, submissionId, fulfiller, resultHash, proof);
    }
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @dev Test-only stand-in for an ERC-8414 task token. Implements just the machine-settled
///      path the adapter depends on, following the ERC-8414 draft's rules: settlement is
///      permissionless, the task calls `verifyFulfillment` on its acceptance authority, a
///      false return reverts settlement without rejecting, and the payout is the fixed
///      `rewardPerCompletion`. Not a conforming ERC-8414 implementation.
interface IVerifier {
    function verifyFulfillment(address, uint256, uint256, address, bytes32, bytes calldata) external returns (bool);
    function supportsInterface(bytes4) external view returns (bool);
}

contract MockTaskToken {
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

    struct Submission {
        address fulfiller;
        bytes32 resultHash;
        bool accepted;
    }

    mapping(uint256 => address) public updateAuthorityOf;
    mapping(uint256 => address) public acceptanceAuthorityOf;
    mapping(uint256 => TenderTerms) private _terms;
    mapping(uint256 => uint256) public escrowBalanceOf;
    mapping(uint256 => uint64) public completionsOf;
    mapping(uint256 => Submission[]) private _subs;

    event FulfillmentSubmitted(uint256 indexed tokenId, uint256 indexed submissionId, address indexed fulfiller, bytes32 resultHash);
    event FulfillmentAccepted(uint256 indexed tokenId, uint256 indexed submissionId, address indexed fulfiller, uint256 reward);

    function mint(uint256 tokenId, address updateAuthority, address acceptanceAuthority, uint256 reward, uint64 maxCompletions)
        external
        payable
    {
        require(updateAuthorityOf[tokenId] == address(0), "exists");
        updateAuthorityOf[tokenId] = updateAuthority;
        acceptanceAuthorityOf[tokenId] = acceptanceAuthority;
        _terms[tokenId] = TenderTerms(address(0), reward, maxCompletions, 0, 0, 0, 0, 1 days);
        escrowBalanceOf[tokenId] = msg.value;
    }

    function tenderTermsOf(uint256 tokenId) external view returns (TenderTerms memory) {
        return _terms[tokenId];
    }

    function submitFulfillment(uint256 tokenId, bytes32 resultHash) external returns (uint256 id) {
        _subs[tokenId].push(Submission(msg.sender, resultHash, false));
        id = _subs[tokenId].length; // ids start at 1
        emit FulfillmentSubmitted(tokenId, id, msg.sender, resultHash);
    }

    function settleFulfillment(uint256 tokenId, uint256 submissionId, bytes calldata proof) external {
        Submission storage s = _subs[tokenId][submissionId - 1];
        require(!s.accepted, "settled");
        TenderTerms memory t = _terms[tokenId];
        require(t.maxCompletions == 0 || completionsOf[tokenId] < t.maxCompletions, "bound reached");
        require(escrowBalanceOf[tokenId] >= t.rewardPerCompletion, "insolvent");
        IVerifier v = IVerifier(acceptanceAuthorityOf[tokenId]);
        require(v.supportsInterface(0x9977db15), "not machine-settled");
        require(v.verifyFulfillment(address(this), tokenId, submissionId, s.fulfiller, s.resultHash, proof), "proof does not establish fulfillment");

        s.accepted = true;
        completionsOf[tokenId]++;
        escrowBalanceOf[tokenId] -= t.rewardPerCompletion;
        (bool ok,) = s.fulfiller.call{value: t.rewardPerCompletion}("");
        require(ok, "payout failed");
        emit FulfillmentAccepted(tokenId, submissionId, s.fulfiller, t.rewardPerCompletion);
    }
}

/// @dev Test-only inner verifier: the work is "know the preimage of answerHash", and the
///      submission's resultHash must bind that preimage to the fulfiller, as ERC-8414's
///      Security Considerations recommend against proof front-running.
contract MockHashlockVerifier {
    bytes32 public immutable answerHash;

    constructor(bytes32 answerHash_) {
        answerHash = answerHash_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x9977db15 || id == 0x01ffc9a7;
    }

    function verifyFulfillment(address, uint256, uint256, address fulfiller, bytes32 resultHash, bytes calldata proof)
        external
        view
        returns (bool)
    {
        return keccak256(proof) == answerHash && resultHash == keccak256(abi.encode(proof, fulfiller));
    }
}

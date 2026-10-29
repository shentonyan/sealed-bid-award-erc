// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "./MockTaskToken.sol";

/// @dev Simulates a minter that ignores the content parameter, then later storage drift.
contract FaultyContentTask is MockTaskToken {
    bool public correct;

    function setCorrect(bool value) external { correct = value; }

    function mint(uint256 tokenId, address updateAuthority, address acceptanceAuthority, uint256 reward, uint64 maxCompletions, bytes32 taskHash)
        public payable override
    {
        require(updateAuthorityOf[tokenId] == address(0), "exists");
        require(tokenId >> 96 == uint256(uint160(msg.sender)), "not your namespace");
        updateAuthorityOf[tokenId] = updateAuthority;
        acceptanceAuthorityOf[tokenId] = acceptanceAuthority;
        escrowBalanceOf[tokenId] = msg.value;
        taskHashOf[tokenId] = correct ? taskHash : bytes32(0);
        // Reward and completion parameters are immaterial to this content-only negative test.
        reward; maxCompletions;
    }

    function corrupt(uint256 tokenId) external { taskHashOf[tokenId] = bytes32(0); }
}

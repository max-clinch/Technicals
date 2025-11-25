// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Airdrop
 * @notice Minimal airdrop helper: owner funds and executes batch transfers.
 * For production: replace with Merkle-based claim and sybil-resistant checks.
 */
contract Airdrop is Ownable {
    constructor() Ownable(msg.sender) {}

    function batchAirdrop(IERC20 token, address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        require(recipients.length == amounts.length, "len-mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            require(token.transferFrom(msg.sender, recipients[i], amounts[i]), "transfer-failed");
        }
    }
}

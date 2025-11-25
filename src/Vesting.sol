// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Vesting
 * @notice Simple cliff + linear vesting contract for team/advisors
 */
contract Vesting is Ownable {
    IERC20 public immutable TOKEN;

    struct Grant {
        uint256 total;
        uint256 released;
        uint64 start; // unix
        uint64 cliff; // seconds
        uint64 duration; // seconds
    }

    mapping(address => Grant) public grants;

    event GrantAdded(address indexed who, uint256 total);
    event Released(address indexed who, uint256 amount);

    constructor(IERC20 _token) Ownable(msg.sender) {
        TOKEN = _token;
    }

    function addGrant(address who, uint256 total, uint64 start, uint64 cliff, uint64 duration) external onlyOwner {
        require(grants[who].total == 0, "grant-exists");
        require(duration > 0, "duration>0");
        grants[who] = Grant({total: total, released: 0, start: start, cliff: cliff, duration: duration});
        emit GrantAdded(who, total);
    }

    function releasable(address who) public view returns (uint256) {
        Grant memory g = grants[who];
        if (g.total == 0) return 0;
        if (block.timestamp < g.start + g.cliff) return 0;
        uint256 vested;
        if (block.timestamp >= g.start + g.duration) vested = g.total;
        else vested = (g.total * (block.timestamp - g.start)) / g.duration;
        return vested - g.released;
    }

    function release() external {
        uint256 r = releasable(msg.sender);
        require(r > 0, "none");
        grants[msg.sender].released += r;
        require(TOKEN.transfer(msg.sender, r), "transfer-failed");
        emit Released(msg.sender, r);
    }
}

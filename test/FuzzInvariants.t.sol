// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACTXToken} from "../src/ACTXToken.sol";

contract FuzzInvariants is Test {
    ACTXToken internal token;
    address internal treasury = address(0xBEEF);
    address internal reservoir = address(0xDEAD);

    function setUp() public {
        ACTXToken implementation = new ACTXToken();
        bytes memory initData =
            abi.encodeWithSelector(ACTXToken.initialize.selector, "ACT.X Token", "ACTX", treasury, reservoir, 200);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        token = ACTXToken(address(proxy));
    }

    function testFuzz_totalSupplyConstant(uint96 sendAmount, uint160 recipientSeed) public {
        address recipient = address(recipientSeed);
        vm.assume(recipient != address(0));

        uint256 amount = bound(uint256(sendAmount), 1 ether, 1_000_000 ether);
        vm.prank(treasury);
        assertTrue(token.transfer(recipient, amount));

        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function testFuzz_taxRateSetterBounds(uint16 newTaxBps) public {
        if (newTaxBps > token.MAX_TAX_BPS()) {
            vm.expectRevert("tax-too-high");
            vm.prank(treasury);
            token.setTaxRate(newTaxBps);
        } else {
            vm.prank(treasury);
            token.setTaxRate(newTaxBps);
            assertEq(token.taxRateBasisPoints(), newTaxBps);
        }
    }

    function testFuzz_rewardPoolAccounting(uint96 amount, uint160 recipientSeed) public {
        uint256 rewardAmount = bound(uint256(amount), 1 ether, 1_000 ether);
        address recipient = address(recipientSeed);
        vm.assume(recipient != address(0));

        vm.prank(treasury);
        token.fundRewardPool(rewardAmount);
        assertEq(token.rewardPoolBalance(), rewardAmount);

        vm.prank(treasury);
        token.distributeReward(recipient, rewardAmount);

        assertEq(token.balanceOf(recipient), rewardAmount);
        assertEq(token.rewardPoolBalance(), 0);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }
}


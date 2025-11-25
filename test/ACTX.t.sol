// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACTXToken} from "../src/ACTXToken.sol";

error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

/// @title ACTXToken test suite
/// @author Suleman Ismaila
contract ACTXTest is Test {
    ACTXToken internal token;
    address internal treasury = address(0xBEEF);
    address internal reservoir = address(0xDEAD);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal backend = address(0xBADD);
    uint16 internal initialTaxBps = 200; // 2%

    function setUp() public {
        ACTXToken implementation = new ACTXToken();
        bytes memory initData = abi.encodeWithSelector(
            ACTXToken.initialize.selector, "ACT.X Token", "ACTX", treasury, reservoir, initialTaxBps
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        token = ACTXToken(address(proxy));

        vm.startPrank(treasury);
        token.grantRole(token.REWARD_MANAGER_ROLE(), backend);
        vm.stopPrank();
    }

    function test_totalSupplyMintedToTreasury() public {
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        assertEq(token.balanceOf(treasury), token.TOTAL_SUPPLY());
    }

    function test_transfer_appliesTax() public {
        vm.prank(treasury);
        assertTrue(token.transfer(alice, 100 ether));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether)); // 2% tax = 0.2

        assertEq(token.balanceOf(bob), 9.8 ether);
        assertEq(token.balanceOf(reservoir), 0.2 ether);
    }

    function test_taxExemptAddressesSkipTax() public {
        vm.prank(treasury);
        token.setTaxExempt(alice, true);

        vm.prank(treasury);
        assertTrue(token.transfer(alice, 10 ether));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));

        assertEq(token.balanceOf(reservoir), 0);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_reservoirUpdateMovesExemptions() public {
        address newReservoir = address(0xABCD);

        vm.prank(treasury);
        token.setReservoirAddress(newReservoir);

        assertEq(token.reservoirAddress(), newReservoir);
        assertTrue(token.isTaxExempt(newReservoir));
    }

    function test_rewardFlow_distributeFromPool() public {
        vm.prank(treasury);
        token.fundRewardPool(1_000 ether);
        assertEq(token.rewardPoolBalance(), 1_000 ether);

        vm.prank(backend);
        token.distributeRewardWithContext(alice, 100 ether, keccak256("MEDIA_SESSION"));

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.rewardPoolBalance(), 900 ether);
    }

    function test_rewardDistributionRequiresPoolBalance() public {
        vm.expectRevert(bytes("insufficient-pool"));
        vm.prank(backend);
        token.distributeReward(alice, 1 ether);
    }

    function test_onlyRewardManagersCanDistribute() public {
        vm.prank(treasury);
        token.fundRewardPool(1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, alice, token.REWARD_MANAGER_ROLE())
        );
        vm.prank(alice);
        token.distributeReward(bob, 1 ether);
    }

    function test_withdrawRewardPool() public {
        vm.prank(treasury);
        token.fundRewardPool(5 ether);

        vm.prank(treasury);
        token.withdrawFromPool(bob, 2 ether);

        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.rewardPoolBalance(), 3 ether);
    }

    function test_setRewardPoolMigratesBalance() public {
        vm.prank(treasury);
        token.fundRewardPool(10 ether);

        address newPool = address(0xFEED);
        vm.prank(treasury);
        token.setRewardPool(newPool);

        assertEq(token.rewardPool(), newPool);
        assertEq(token.balanceOf(newPool), 10 ether);
        assertTrue(token.isTaxExempt(newPool));
    }

    function test_onlyAdminCanUpgrade() public {
        ACTXTokenV2 newImpl = new ACTXTokenV2();

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, alice, token.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(alice);
        token.upgradeToAndCall(address(newImpl), "");

        vm.prank(treasury);
        token.upgradeToAndCall(address(newImpl), "");
        assertEq(ACTXTokenV2(address(token)).version(), "v2");
    }
}

/// @author Suleman Ismaila
contract ACTXTokenV2 is ACTXToken {
    function version() external pure returns (string memory) {
        return "v2";
    }
}


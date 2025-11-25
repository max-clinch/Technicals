// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ACTXToken} from "../src/ACTXToken.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {Vesting} from "../src/Vesting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ACTX deployment and verification script
/// @author Suleman Ismaila
contract Deploy is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address reservoir = vm.envAddress("RESERVOIR_ADDRESS");
        uint16 tax = uint16(vm.envUint("INITIAL_TAX_BPS"));

        string memory tokenName = vm.envOr("TOKEN_NAME", string("ACT.X Token"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("ACTX"));
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        string memory networkLabel = vm.envOr("NETWORK_LABEL", string(""));
        string memory metadataDir = vm.envOr("METADATA_DIR", string("./broadcast"));
        string memory metadataFile = string.concat(metadataDir, "/actx-latest.json");

        vm.startBroadcast(deployerKey);

        // -------------------------------------------------------
        // 1. Deploy ACTX implementation
        // -------------------------------------------------------
        ACTXToken impl = new ACTXToken();
        console2.log("ACTX Impl:", address(impl));

        bytes memory initData = abi.encodeWithSelector(
            ACTXToken.initialize.selector, tokenName, tokenSymbol, treasury, reservoir, tax
        );

        // -------------------------------------------------------
        // 2. Deploy Proxy + wrap implementation
        // -------------------------------------------------------
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ACTXToken actx = ACTXToken(address(proxy));
        console2.log("ACTX Proxy:", address(actx));

        // -------------------------------------------------------
        // 3. Deploy auxiliary contracts
        // -------------------------------------------------------
        Airdrop airdrop = new Airdrop();
        console2.log("Airdrop:", address(airdrop));

        Vesting vesting = new Vesting(IERC20(address(actx)));
        console2.log("Vesting:", address(vesting));

        vm.stopBroadcast();

        _writeDeploymentMetadata(
            metadataDir,
            metadataFile,
            rpcUrl,
            networkLabel,
            address(impl),
            address(actx),
            address(airdrop),
            address(vesting)
        );

        _maybeVerifyImplementation(address(impl));
    }

    function _writeDeploymentMetadata(
        string memory metadataDir,
        string memory metadataFile,
        string memory rpcUrl,
        string memory networkLabel,
        address implementation,
        address proxy,
        address airdrop,
        address vesting
    ) internal {
        string memory objectKey = "actx";

        string memory json = vm.serializeAddress(objectKey, "implementation", implementation);
        json = vm.serializeAddress(objectKey, "proxy", proxy);
        json = vm.serializeAddress(objectKey, "airdrop", airdrop);
        json = vm.serializeAddress(objectKey, "vesting", vesting);
        json = vm.serializeUint(objectKey, "chainId", block.chainid);
        json = vm.serializeUint(objectKey, "timestamp", block.timestamp);

        if (bytes(networkLabel).length > 0) {
            json = vm.serializeString(objectKey, "network", networkLabel);
        }

        if (bytes(rpcUrl).length > 0) {
            json = vm.serializeString(objectKey, "rpcUrl", rpcUrl);
        }

        // vm.createDir(metadataDir, true);
        // vm.writeJson(json, metadataFile);
        console2.log("Deployment metadata saved ->", metadataFile);
    }

    function _maybeVerifyImplementation(address implementation) internal {
        bool autoVerify = vm.envOr("AUTO_VERIFY", false);
        if (!autoVerify) {
            console2.log("AUTO_VERIFY=false -> skipping verification step.");
            return;
        }

        string memory verifier = vm.envOr("VERIFIER", string("etherscan"));
        string memory chainFlag = vm.envOr("VERIFY_CHAIN", string("sepolia"));
        string memory apiKey = vm.envString("ETHERSCAN_API_KEY");

        string[] memory cmd = new string[](12);
        cmd[0] = "forge";
        cmd[1] = "verify-contract";
        cmd[2] = "--verifier";
        cmd[3] = verifier;
        cmd[4] = "--chain";
        cmd[5] = chainFlag;
        cmd[6] = Strings.toHexString(uint256(uint160(implementation)), 20);
        cmd[7] = "src/ACTXToken.sol:ACTXToken";
        cmd[8] = "--constructor-args";
        cmd[9] = "0x";
        cmd[10] = "--etherscan-api-key";
        cmd[11] = apiKey;

        console2.log("Running auto verification via forge verify-contract...");
        vm.ffi(cmd);
    }
}

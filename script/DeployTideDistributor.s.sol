// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {HarborTideDistributor_v1} from "@tide/HarborTideDistributor_v1.sol";

/// @notice Deploy HarborTideDistributor_v1 (one-shot, non-upgradeable TGE distributor).
/// @dev Constructor args are read from a JSON config file (default: `deployments/deploy-config.json`;
///      override with `DEPLOY_CONFIG_FILE`). Writes `deployments/aux-<chainId>.json` for script/verify.sh.
///
/// Usage:
///   forge script script/DeployTideDistributor.s.sol:DeployTideDistributor \
///     --rpc-url mainnet --broadcast --slow --timeout 600 --account deployer --sender <deployer>
contract DeployTideDistributor is Script {
    address internal constant DEFAULT_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    address internal constant DEFAULT_VEBAO = 0x8Bf70DFE40F07a5ab715F7e888478d9D3680a2B6;
    uint256 internal constant DEFAULT_SNAPSHOT_BLOCK = 25_000_000;
    string internal constant DEFAULT_CONFIG_PATH = "deployments/deploy-config.json";

    struct DeployConfig {
        address tide;
        address bao;
        address veBao;
        uint256 startDate;
        uint256 endDate;
        uint256 snapshotBlock;
        address multisig;
        bytes32 veBaoMerkleRoot;
        bytes32 standardMerkleRoot;
    }

    function run() external {
        DeployConfig memory cfg = _loadConfig();

        require(cfg.tide != address(0) && cfg.bao != address(0), "config: tide and bao required");
        require(cfg.startDate > 0 && cfg.endDate > cfg.startDate, "config: startDate and endDate required");
        require(
            cfg.veBaoMerkleRoot != bytes32(0) && cfg.standardMerkleRoot != bytes32(0), "config: merkle roots required"
        );

        vm.startBroadcast();
        HarborTideDistributor_v1 distributor = new HarborTideDistributor_v1(
            cfg.tide,
            cfg.bao,
            cfg.veBao,
            cfg.startDate,
            cfg.endDate,
            cfg.snapshotBlock,
            cfg.multisig,
            cfg.veBaoMerkleRoot,
            cfg.standardMerkleRoot
        );
        vm.stopBroadcast();

        _writeAux(
            address(distributor),
            cfg.tide,
            cfg.bao,
            cfg.veBao,
            cfg.startDate,
            cfg.endDate,
            cfg.snapshotBlock,
            cfg.multisig,
            cfg.veBaoMerkleRoot,
            cfg.standardMerkleRoot
        );

        console.log("HarborTideDistributor_v1 deployed on chainId %s", block.chainid);
        console.log("  distributor %s", address(distributor));
        console.log("  config      -> %s", _configPath());
        console.log("  aux         -> deployments/aux-%s.json", block.chainid);
        console.log("Next: fund with up to 280,000,000 TIDE (<=250m paths 1+2, <=30m path 3).");
    }

    function _configPath() internal view returns (string memory) {
        return vm.envOr("DEPLOY_CONFIG_FILE", DEFAULT_CONFIG_PATH);
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        string memory path = _configPath();
        require(vm.exists(path), string.concat("config file not found: ", path));
        string memory json = vm.readFile(path);

        cfg.tide = vm.parseJsonAddress(json, ".tide");
        cfg.bao = vm.parseJsonAddress(json, ".bao");
        cfg.startDate = vm.parseJsonUint(json, ".startDate");
        cfg.endDate = vm.parseJsonUint(json, ".endDate");
        cfg.veBaoMerkleRoot = vm.parseJsonBytes32(json, ".veBaoMerkleRoot");
        cfg.standardMerkleRoot = vm.parseJsonBytes32(json, ".standardMerkleRoot");

        cfg.veBao = vm.keyExistsJson(json, ".veBao") ? vm.parseJsonAddress(json, ".veBao") : DEFAULT_VEBAO;
        cfg.snapshotBlock = vm.keyExistsJson(json, ".snapshotBlock")
            ? vm.parseJsonUint(json, ".snapshotBlock")
            : DEFAULT_SNAPSHOT_BLOCK;
        cfg.multisig = vm.keyExistsJson(json, ".multisig") ? vm.parseJsonAddress(json, ".multisig") : DEFAULT_MULTISIG;
    }

    function _auxPath(uint256 chainId) internal view returns (string memory) {
        return string.concat("deployments/aux-", vm.toString(chainId), ".json");
    }

    function _writeAux(
        address distributor,
        address tide,
        address bao,
        address veBao,
        uint256 startDate,
        uint256 endDate,
        uint256 snapshotBlock,
        address multisig,
        bytes32 veBaoMerkleRoot,
        bytes32 standardMerkleRoot
    ) internal {
        vm.createDir("deployments", true);
        string memory obj = "tide-distributor-aux";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "distributor", distributor);
        vm.serializeAddress(obj, "tide", tide);
        vm.serializeAddress(obj, "bao", bao);
        vm.serializeAddress(obj, "veBao", veBao);
        vm.serializeUint(obj, "startDate", startDate);
        vm.serializeUint(obj, "endDate", endDate);
        vm.serializeUint(obj, "snapshotBlock", snapshotBlock);
        vm.serializeAddress(obj, "multisig", multisig);
        vm.serializeBytes32(obj, "veBaoMerkleRoot", veBaoMerkleRoot);
        string memory json = vm.serializeBytes32(obj, "standardMerkleRoot", standardMerkleRoot);
        vm.writeJson(json, _auxPath(block.chainid));
    }
}

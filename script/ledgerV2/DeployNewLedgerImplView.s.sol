// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../../src/LedgerImplView.sol";
import "../utils/BaseScript.s.sol";
import "../utils/ConfigHelper.s.sol";

contract DeployNewLedgerImplView is BaseScript, ConfigHelper {
    function run() external {
        uint256 orderlyPrivateKey = vm.envUint("ORDERLY_PRIVATE_KEY");

        vm.startBroadcast(orderlyPrivateKey);
        LedgerImplView ledgerImplView = new LedgerImplView();
        console.log("new ledgerImplView Address: ", address(ledgerImplView));
        vm.stopBroadcast();

        console.log("All done!");
    }
}

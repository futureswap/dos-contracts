// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../dos/DOS.sol";
import "../dos/DSafeProxy.sol";
import "../dos/VersionManager.sol";
import "../interfaces/IVersionManager.sol";
import "../lib/FsMath.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableVersion.sol";

contract Echidna2 {
  // SETUP STUFF, I THINK I DID THIS PART RIGHT:
  VersionManager public versionManager;
  DOSConfig public dosConfig;
  DOS public dos;
  DSafeLogic public dSafeLogic;
  DSafeProxy public proxy1;
  constructor() public {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new DOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));

    IDOSConfig(address(dos)).setConfig(
            IDOSConfig.Config({
                treasurySafe: address(0),
                treasuryInterestFraction: 0,
                maxSolvencyCheckGasCost: 10_000_000,
                liqFraction: 8e17,
                fractionalReserveLeverage: 10
            })
        );

    //dosConfig.setVersionManager(address(versionManager));

    versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(dSafeLogic));
    //string memory versionName = string(FsUtils.decodeFromBytes32(dSafeLogic.immutableVersion()));
    versionManager.markRecommendedVersion("1.0.0");

    // pretty sure everything up here is good

    proxy1 = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
  }
  function ensureProxyNonzero() public { // fails in assert mode, meaning proxy1 is nonzero
    if (address(proxy1) != address(0))
      assert(false);
  }
  // ONE OF THESE TWO SHOULD WORK:
  function tryToCall1() public { // passes in assert mode, meaning the call isn't working
    DSafeProxy(payable(address(proxy1))).executeBatch(new Call[](0));
  }
  function tryToCall2() public { // passes in assert mode, meaning the call isn't working
    DSafeLogic(payable(address(proxy1))).executeBatch(new Call[](0));
  }
}
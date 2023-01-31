// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../dos/DOS.sol";
import "../dos/DSafeProxy.sol";
import "../dos/VersionManager.sol";
import "../interfaces/IVersionManager.sol";
import "../lib/FsMath.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableVersion.sol";

// echidna-test . --config echidna.yaml --contract Echidna
contract Echidna {
  constructor() public {
    initDos();
  }

  function testExp(int256 xa, int256 xb) public {
    int256 x = xa*FsMath.FIXED_POINT_SCALE+xb;
    int256 result = FsMath.exp(x);
    int256 epsilon = int256(1)<<uint256(10); // 2^10, far less than FIXED_POINT_SCALE

    if (x >= 0)
      assert(result >= FsMath.FIXED_POINT_SCALE);
    if (x >= epsilon)
      assert(result > FsMath.FIXED_POINT_SCALE);
    if (x <= 0)
      assert(result <= FsMath.FIXED_POINT_SCALE);
    if (x <= -epsilon)
      assert(result < FsMath.FIXED_POINT_SCALE);
  }

  function testPow(int256 xa, int256 xb, int256 n) public {
    int256 x = xa*FsMath.FIXED_POINT_SCALE+xb;
    int256 result = FsMath.pow(x,n);

    int256 signExpected = FsMath.sign(x);
    if (n % 2 == 0 && signExpected == -1) // when n is even, x^n is positive
      signExpected = 1;

    if (n == 0) // x^0 = 1
      assert(result == FsMath.FIXED_POINT_SCALE);
    else if (n < 0 || (x > -FsMath.FIXED_POINT_SCALE && x < FsMath.FIXED_POINT_SCALE)) // if n is negative or |x| < 1, x^n can round to 0
      assert(FsMath.sign(result) == signExpected || result == 0);
    else
      assert(FsMath.sign(result) == signExpected);
  }

  function testSqrt(int256 xa, int256 xb) public {
    int256 x = xa*FsMath.FIXED_POINT_SCALE+xb;
    require(x >= 0, "Must be positive");
    require(x <= 100*FsMath.FIXED_POINT_SCALE, "Too big");
    int256 result = FsMath.sqrt(x);

    assert(result >= 0);
    if (x >= FsMath.FIXED_POINT_SCALE)
      assert(result <= x);
    else
      assert(result >= x);
  }

  VersionManager public versionManager;
  DOSConfig public dosConfig;
  EchidnaDOS public dos;
  DSafeLogic public dSafeLogic;

  // some proxies for echidna to work with; more can be created at will with addProxy, but echidna seems to have a hard time calling those directly, since they're in a list instead of a member variable
  DSafeProxy public proxy1;
  DSafeProxy public proxy2;
  DSafeProxy public proxy3;
  DSafeProxy public proxy4;

  function initDos() internal {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new EchidnaDOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));

    IDOS(address(dos)).setConfig(IDOSConfig.Config(
      /* treasurySafe: */ address(this), // todo: update to a dWallet address
      /* treasuryInterestFraction: */ 5e16, // toWei(0.05),
      /* maxSolvencyCheckGasCost: */ 1e6,
      /* liqFraction: */ 8e17, // toWei(0.8),
      /* fractionalReserveLeverage: */ 9
    ));

    dosConfig.setVersionManager(address(versionManager));

    versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(dSafeLogic));
    string memory versionName = string(FsUtils.decodeFromBytes32(dSafeLogic.immutableVersion()));
    versionManager.markRecommendedVersion(versionName);

    proxy1 = genProxy();
    proxy2 = genProxy();
    proxy3 = genProxy();
    proxy4 = genProxy();

    selectedProxy = proxy1;
    proxies.push(proxy1);
    proxies.push(proxy2);
    proxies.push(proxy3);
    proxies.push(proxy4);
  }

  function genProxy() public returns (DSafeProxy) {
    return DSafeProxy(payable(IDOS(address(dos)).createDSafe()));
  }

  function verifyDOS() public {
    assert(dos.invariant());
  }

  // setup to make it easier for echidna to call executeBatch
  // function calls to make and select proxies, to add calls to a list, and then call executeBatch with those calls
  // eventually we'll add functions to add deposit and withdraw calls to the list

  DSafeProxy[] public proxies; // proxies we've made
  DSafeProxy public selectedProxy; // which one we want to call executeBatch with
  Call[] public calls; // calls to feed to executeBatch

  function addProxy() public {
    proxies.push(genProxy());
  }
  function selectProxy(uint256 n) public {
    selectedProxy = proxies[n % proxies.length];
  }
  function addCall(Call calldata call) public {
    calls.push(call);
  }
  // TODO addDepositCall, addWithdrawCall, etc would go here
  function execCalls() public {
    selectedProxy.executeBatch(calls);
    calls = new Call[](0); // reset call list afterwards
  }
}

contract EchidnaDOS is DOS {
  constructor(address _dosConfig, address _versionManager) DOS(_dosConfig, _versionManager) {}
  function invariant() public returns (bool) {
    return true; // edit this to add rules
  }
}

// can add more of these contracts if you want invariants on more contracts

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
  DOS public dos;
  DSafeLogic public dSafeLogic;
  DSafeProxy public proxy1_1;
  DSafeProxy public proxy1_2;
  DSafeProxy public proxy2_1;
  DSafeProxy public proxy2_2;
  DSafeProxy public proxy3_1;
  DSafeProxy public proxy3_2;
  function initDos() internal {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new DOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));

    dosConfig.setVersionManager(address(versionManager));

    versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(dSafeLogic));
    string memory versionName = string(FsUtils.decodeFromBytes32(dSafeLogic.immutableVersion()));
    versionManager.markRecommendedVersion(versionName);

    proxy1_1 = DSafeProxy(payable(dosConfig._createDSafe(address(0x10000))));
    proxy1_2 = DSafeProxy(payable(dosConfig._createDSafe(address(0x10000))));
    proxy2_1 = DSafeProxy(payable(dosConfig._createDSafe(address(0x20000))));
    proxy2_2 = DSafeProxy(payable(dosConfig._createDSafe(address(0x20000))));
    proxy3_1 = DSafeProxy(payable(dosConfig._createDSafe(address(0x30000))));
    proxy3_2 = DSafeProxy(payable(dosConfig._createDSafe(address(0x30000))));
  }
}
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/FsMath.sol";

import "../dos/DOS.sol";
import "../dos/VersionManager.sol";

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

  DOSConfig public dosConfig;
  VersionManager public versionManager;
  DOS public dos;
  function initDos() internal {
    dosConfig = new DOSConfig(address(this));
    versionManager = new VersionManager(address(this));
    dos = new DOS(address(dosConfig), address(versionManager));
  }
}

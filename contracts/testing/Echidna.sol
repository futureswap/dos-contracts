// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../dos/DOS.sol";
import "../dos/DSafeProxy.sol";
import "../dos/VersionManager.sol";
import "../interfaces/IVersionManager.sol";
import "../lib/FsMath.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableVersion.sol";
import "../testing/MockERC20Oracle.sol";
import "../testing/TestERC20.sol";

// echidna-test . --config echidna.yaml --contract EchidnaMath
// echidna-test . --config echidna.yaml --contract EchidnaDOSTests

contract EchidnaMathTests {
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
}

contract EchidnaDOSTests {
  VersionManager public versionManager;
  DOSConfig public dosConfig;
  EchidnaDOS public dos;
  DSafeLogic public dSafeLogic;

  TestERC20 public usdc;
  TestERC20 public uni;
  MockERC20Oracle public usdcOracle;
  MockERC20Oracle public uniOracle;

  // some proxies for echidna to work with; more can be created at will with addProxy, but echidna seems to have a hard time calling those directly, since they're in a list instead of a member variable
  DSafeProxy public proxy1;
  DSafeProxy public proxy2;
  DSafeProxy public proxy3;
  DSafeProxy public proxy4;

  constructor() public {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new EchidnaDOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));

    usdc = new TestERC20("USDC", "USDC", 6);
    uni = new TestERC20("UNI", "UNI", 18);
    usdcOracle = new MockERC20Oracle(address(this));
    uniOracle = new MockERC20Oracle(address(this));

    usdcOracle.setPrice(1e18, 6, 6);
    uniOracle.setPrice(840e18, 6, 18);

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

    IDOS(address(dos)).addERC20Info(
      address(usdc),
      usdc.name(),
      usdc.symbol(),
      usdc.decimals(),
      address(usdcOracle),
      0,
      0,
      0,
      0
    );

    IDOS(address(dos)).addERC20Info(
      address(uni),
      uni.name(),
      uni.symbol(),
      uni.decimals(),
      address(uniOracle),
      0,
      0,
      0,
      0
    );

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

  function execCalls() public {
    selectedProxy.executeBatch(calls);
    calls = new Call[](0); // reset call list afterwards
  }

  function addCall(Call calldata call) public {
    calls.push(call);
  }

  function methodSigBytes(bytes memory methodSig) internal returns (bytes4) {
    return bytes4(keccak256(methodSig));
  }
  function addrToBytes(address addr) internal returns (bytes32) {
    return bytes32(uint256(uint160(addr)));
  }

  // TODO make these use preset erc20 addresses instead of arbitrary addresses
  function addDepositERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC20(address,uint256)"),addrToBytes(erc20),bytes32(amount)), 0));
  }
  function addDepositERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC721(address,uint256)"),addrToBytes(erc721),bytes32(tokenId)), 0));
  }
  function addWithdrawERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC20(address,uint256)"),addrToBytes(erc20),bytes32(amount)), 0));
  }
  function addWithdrawERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC721(address,uint256)"),addrToBytes(erc721),bytes32(tokenId)), 0));
  }
  function addTransferERC20Call(address erc20, address to, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC20(address,address,uint256)"),addrToBytes(erc20),addrToBytes(to),bytes32(tokenId)), 0));
  }
  function addTransferERC721Call(address erc721, uint256 tokenId, address to) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC721(address,uint256,address)"),addrToBytes(erc721),bytes32(tokenId),addrToBytes(to)), 0));
  }
  function addLiquidateCall(address dSafe) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("liquidate(address)"),bytes32(uint256(uint160(dSafe)))), 0));
  }
  // TODO there's some others too
}

contract EchidnaDOS is DOS {
  constructor(address _dosConfig, address _versionManager) DOS(_dosConfig, _versionManager) {}
  function invariant() public returns (bool) {
    return true; // edit this to add rules
  }
}

// can add more of these contracts if you want invariants on more contracts

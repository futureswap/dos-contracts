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
import "../testing/external/WETH9.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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
  // most of the setup here copied from deploy.ts

  VersionManager public versionManager;
  DOSConfig public dosConfig;
  EchidnaDOS public dos;
  DSafeLogic public dSafeLogic;

  TestERC20 public usdc;
  TestERC20 public uni;
  WETH9 public weth;
  MockERC20Oracle public usdcOracle;
  MockERC20Oracle public uniOracle;
  MockERC20Oracle public wethOracle;

  IERC20[] public erc20s;
  IERC721[] public erc721s;

  // some dSafes for echidna to work with; more can be created at will with addProxy, but echidna seems to have a hard time calling those directly, since they're in a list instead of a member variable
  DSafeProxy public dSafe1;
  DSafeProxy public dSafe2;
  DSafeProxy public dSafe3;
  DSafeProxy public dSafe4;

  // TODO give users some erc20s to work with

  constructor() public {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new EchidnaDOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));

    usdc = new TestERC20("USDC", "USDC", 6);
    uni = new TestERC20("UNI", "UNI", 18);
    weth = new WETH9();
    usdcOracle = new MockERC20Oracle(address(this));
    uniOracle = new MockERC20Oracle(address(this));
    wethOracle = new MockERC20Oracle(address(this));

    erc20s.push(usdc);
    erc20s.push(uni);
    erc20s.push(weth);

    usdcOracle.setPrice(1e18, 6, 6);
    uniOracle.setPrice(840e18, 6, 18);
    wethOracle.setPrice(1200e18, 6, 18);

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

    IDOS(address(dos)).addERC20Info(
      address(weth),
      weth.name(),
      weth.symbol(),
      weth.decimals(),
      address(wethOracle),
      0,
      0,
      0,
      0
    );

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

    dSafe1 = genDSafeProxy();
    dSafe2 = genDSafeProxy();
    dSafe3 = genDSafeProxy();
    dSafe4 = genDSafeProxy();

    selectedProxy = dSafe1;
    dSafes.push(dSafe1);
    dSafes.push(dSafe2);
    dSafes.push(dSafe3);
    dSafes.push(dSafe4);
  }

  function genDSafeProxy() public returns (DSafeProxy) {
    return DSafeProxy(payable(IDOS(address(dos)).createDSafe()));
  }

  function verifyDOS() public {
    assert(dos.invariant());
  }

  // setup to make it easier for echidna to call executeBatch
  // function calls to make and select dSafes, to add calls to a list, and then call executeBatch with those calls
  // eventually we'll add functions to add deposit and withdraw calls to the list

  DSafeProxy[] public dSafes; // dSafes we've made
  DSafeProxy public selectedProxy; // which one we want to call executeBatch with
  Call[] public calls; // calls to feed to executeBatch

  function addDSafe() public {
    dSafes.push(genDSafeProxy());
  }

  function selectProxy(uint256 n) public {
    selectedProxy = dSafes[n % dSafes.length];
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
  function dSafeNumToBytes(uint256 dSafeNum) internal returns (bytes32) {
    return addrToBytes(address(dSafes[dSafeNum % dSafes.length]));
  }
  function erc20NumToBytes(uint256 erc20Num) internal returns (bytes32) {
    return addrToBytes(address(erc20s[erc20Num % erc20s.length]));
  }
  function erc721NumToBytes(uint256 erc721Num) internal returns (bytes32) {
    return addrToBytes(address(erc721s[erc721Num % erc721s.length]));
  }

  function addDepositERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC20(address,uint256)"),addrToBytes(erc20),bytes32(amount)), 0));
  }
  function addDepositERC20CallLimited(uint256 erc20Num, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC20(address,uint256)"),erc20NumToBytes(erc20Num),bytes32(amount)), 0));
  }

  function addDepositERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC721(address,uint256)"),addrToBytes(erc721),bytes32(tokenId)), 0));
  }
  function addDepositERC721CallLimited(uint256 erc721Num, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC721(address,uint256)"),erc721NumToBytes(erc721Num),bytes32(tokenId)), 0));
  }

  function addWithdrawERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC20(address,uint256)"),addrToBytes(erc20),bytes32(amount)), 0));
  }
  function addWithdrawERC20CallLimited(uint256 erc20Num, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC20(address,uint256)"),erc20NumToBytes(erc20Num),bytes32(amount)), 0));
  }

  function addWithdrawERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC721(address,uint256)"),addrToBytes(erc721),bytes32(tokenId)), 0));
  }
  function addWithdrawERC721CallLimited(uint256 erc721Num, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("withdrawERC721(address,uint256)"),erc721NumToBytes(erc721Num),bytes32(tokenId)), 0));
  }

  function addTransferERC20Call(address erc20, address to, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC20(address,address,uint256)"),addrToBytes(erc20),addrToBytes(to),bytes32(amount)), 0));
  }
  function addTransferERC20CallLimited(uint256 erc20Num, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC20(address,address,uint256)"),erc20NumToBytes(erc20Num),dSafeNumToBytes(toNum),bytes32(amount)), 0));
  }

  function addTransferERC721Call(address erc721, uint256 tokenId, address to) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC721(address,uint256,address)"),addrToBytes(erc721),bytes32(tokenId),addrToBytes(to)), 0));
  }
  function addTransferERC721CallLimited(uint256 erc721Num, uint256 tokenId, uint256 toNum) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferERC721(address,uint256,address)"),erc721NumToBytes(erc721Num),bytes32(tokenId),dSafeNumToBytes(toNum)), 0));
  }

  function addTransferFromERC20Call(address erc20, address from, address to, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferFromERC20(address,address,address,uint256)"),addrToBytes(erc20),addrToBytes(from),addrToBytes(to),bytes32(amount)), 0));
  }
  function addTransferFromERC20CallLimited(uint256 erc20Num, uint256 fromNum, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferFromERC20(address,address,address,uint256)"),erc20NumToBytes(erc20Num),dSafeNumToBytes(fromNum),dSafeNumToBytes(toNum),bytes32(amount)), 0));
  }

  function addTransferFromERC721Call(address erc721, address from, address to, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferFromERC721(address,address,address,uint256)"),addrToBytes(erc721),addrToBytes(from),addrToBytes(to),bytes32(tokenId)), 0));
  }
  function addTransferFromERC721CallLimited(uint256 erc721Num, uint256 fromNum, uint256 toNum, uint256 tokenId) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferFromERC721(address,address,address,uint256)"),erc721NumToBytes(erc721Num),dSafeNumToBytes(fromNum),dSafeNumToBytes(toNum),bytes32(tokenId)), 0));
  }

  function addOnERC721ReceivedCall(address operator, address from, uint256 tokenId, bytes calldata data) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("onERC721Received(address,address,uint256,bytes)"),addrToBytes(operator),addrToBytes(from),bytes32(tokenId),bytes32(uint256(32*4)),bytes32(data.length),data), 0));
  }
  function addOnERC721ReceivedCallLimited(address operator, uint256 fromNum, uint256 tokenId, bytes calldata data) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("onERC721Received(address,address,uint256,bytes)"),addrToBytes(operator),dSafeNumToBytes(fromNum),bytes32(tokenId),bytes32(uint256(32*4)),bytes32(data.length),data), 0));
  }

  function addDepositERC20ForSafeCall(address erc20, address to, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC20ForSafe(address,address,uint256)"),addrToBytes(erc20),addrToBytes(to),bytes32(amount)), 0));
  }
  function addDepositERC20ForSafeCallLimited(uint256 erc20Num, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("depositERC20ForSafe(address,address,uint256)"),erc20NumToBytes(erc20Num),dSafeNumToBytes(toNum),bytes32(amount)), 0));
  }

  function addLiquidateCall(address dSafe) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("liquidate(address)"),addrToBytes(dSafe)), 0));
  }
  function addLiquidateCallLimited(uint256 dSafeNum) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("liquidate(address)"),dSafeNumToBytes(dSafeNum)), 0));
  }

  function addUpgradeDSafeImplementationCall(string calldata version) public {
    uint256 numPaddingBytes = 32 - (bytes(version).length % 32);
    if (numPaddingBytes == 32) numPaddingBytes = 0;
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("upgradeDSafeImplementation(string)"),bytes32(uint256(32)),bytes32(bytes(version).length),bytes(version),new bytes(numPaddingBytes)), 0));
  }

  function addTransferDSafeOwnershipCall(address newOwner) public {
    calls.push(Call(address(dos), bytes.concat(methodSigBytes("transferDSafeOwnership(address)"),addrToBytes(newOwner)), 0));
  }

  // we leave out the onlyGovernance functions, since midifer onlyGovernance() is pretty airtight
  // and we check that immutableGovernance hasn't changed in EchidnaDOS.invariant()

  // TODO depositFull, withdrawFull, executeBatch, approveAndCall
}

contract EchidnaDOS is DOS {
  constructor(address _dosConfig, address _versionManager) DOS(_dosConfig, _versionManager) {}
  function invariant() public returns (bool) {
    if (DOSConfig(address(this)).immutableGovernance() != msg.sender) return false; // msg.sender will always be EchidnaDOSTests
    // edit this to add rules
    return true;
  }
}

// can add more of these contracts if you want invariants on more contracts

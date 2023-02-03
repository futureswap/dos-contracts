// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../../dos/DOS.sol";
import "../../dos/DSafeProxy.sol";
import "../../dos/VersionManager.sol";
import "../../interfaces/IVersionManager.sol";
import "../../lib/FsMath.sol";
import "../../lib/FsUtils.sol";
import "../../lib/ImmutableVersion.sol";
import "../../testing/MockERC20Oracle.sol";
import "../../testing/TestERC20.sol";
import "../../testing/external/WETH9.sol";
import "../../testing/TestNFT.sol";
import "../../testing/MockNFTOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// echidna-test . --config echidna.yaml --contract EchidnaE2E

contract EchidnaE2E {
  // most of the setup here copied from deploy.ts

  VersionManager versionManager;
  DOSConfig dosConfig;
  EchidnaDOS dos;
  DSafeLogic dSafeLogic;
  MockNFTOracle nftOracle;

  IERC20[] erc20s;
  IERC721[] erc721s;

  // some dSafes for echidna to work with; more can be created at will with addProxy, but echidna seems to have a hard time calling those directly, since they're in a list instead of a member variable
  DSafeProxy  dSafe1;
  DSafeProxy  dSafe2;
  DSafeProxy  dSafe3;
  DSafeProxy  dSafe4;

  // TODO give users some erc20s to work with

  constructor() public {
    versionManager = new VersionManager(address(this));
    dosConfig = new DOSConfig(address(this));
    dos = new EchidnaDOS(address(dosConfig), address(versionManager));
    dSafeLogic = new DSafeLogic(address(dos));
    nftOracle = new MockNFTOracle();

    create_erc20(false, "USDC", "USDC", 6, 1e18, 0, 0, 0, 0);
    create_erc20(false, "UNI", "UNI", 18, 840e18, 0, 0, 0, 0);
    create_erc20(false, "WETH", "WETH", 18, 1200e18, 0, 0, 0, 0);

    create_erc721("Example NFT 1", "NFT1", 0, address(nftOracle));
    create_erc721("Example NFT 2", "NFT2", 0, address(nftOracle));
    create_erc721("Example NFT 3", "NFT3", 3000, address(nftOracle));

    nftOracle.setCollateralFactor(5e17); // toWei(.5)

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

    for(uint256 i; i < 4; i++) {
      genDSafeProxy();
    }

    selectedProxy = dSafes[0];
  }

  function genDSafeProxy() public returns (DSafeProxy proxy) {
    proxy = DSafeProxy(payable(IDOS(address(dos)).createDSafe()));
    dSafes.push(proxy);
  }

  function verifyDOS() public {
    assert(dos.invariant());
  }

  function mintERC20(uint256 dSafeNum, uint256 erc20Num, uint256 amount) public {
    TestERC20(address(erc20s[erc20Num % erc20s.length])).mint(address(dSafes[dSafeNum % dSafes.length]), amount);
    // this cast works even for weth since weth also has a mint function with the same signature
  }

  function mintERC721(uint256 dSafeNum, uint256 erc721Num, int256 price) public returns (uint256 tokenId) {
    TestNFT nft = TestNFT(address(erc721s[erc721Num % erc721s.length]));
    tokenId = nft.mint(address(dSafes[dSafeNum % dSafes.length]));
    nftOracle.setPrice(tokenId, price);
    nft.approve(address(dos), tokenId);
    dos.depositERC721(address(nft), tokenId);
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

  // ******************** Helpers ********************


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

  function erc20NumToAddress(uint256 erc20Num) internal returns (address) {
    return address(erc20s[erc20Num % erc20s.length]);
  }

  function erc721NumToAddress(uint256 erc721Num) internal returns (address) {
    return address(erc721s[erc721Num % erc721s.length]);
  }

  function dSafeNumToAddress(uint256 dSafeNum) internal returns (address) {
    return address(dSafes[dSafeNum % dSafes.length]);
  }

  // ******************** Adding Calls ********************


  function addDepositERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC20(address,uint256)", erc20, amount), 0));
  }
  function addDepositERC20CallLimited(uint256 erc20Num, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC20(address,uint256)", erc20NumToAddress(erc20Num), amount), 0));
  }

  function addDepositERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC721(address,uint256)", erc721, tokenId), 0));
  }
  function addDepositERC721CallLimited(uint256 erc721Num, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC721(address,uint256)", erc721NumToAddress(erc721Num), tokenId), 0));
  }

  function addWithdrawERC20Call(address erc20, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("withdrawERC20(address,uint256)", erc20, amount), 0));
  }
  function addWithdrawERC20CallLimited(uint256 erc20Num, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("withdrawERC20(address,uint256)", erc20NumToAddress(erc20Num), amount), 0));
  }

  function addWithdrawERC721Call(address erc721, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("withdrawERC721(address,uint256)", erc721, tokenId), 0));
  }
  function addWithdrawERC721CallLimited(uint256 erc721Num, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("withdrawERC721(address,uint256)", erc721NumToAddress(erc721Num), tokenId), 0));
  }

  function addTransferERC20Call(address erc20, address to, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferERC20(address,address,uint256)", erc20, to, amount), 0));
  }
  function addTransferERC20CallLimited(uint256 erc20Num, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferERC20(address,address,uint256)", erc20NumToAddress(erc20Num), dSafeNumToAddress(toNum), amount), 0));
  }

  function addTransferERC721Call(address erc721, uint256 tokenId, address to) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferERC721(address,uint256,address)", erc721, tokenId, to), 0));
  }
  function addTransferERC721CallLimited(uint256 erc721Num, uint256 tokenId, uint256 toNum) public {
    calls.push(Call(address(dos),  abi.encodeWithSignature("transferERC721(address,uint256,address)", erc721NumToAddress(erc721Num), tokenId, dSafeNumToAddress(toNum)), 0));
  }

  function addTransferFromERC20Call(address erc20, address from, address to, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferFromERC20(address,address,address,uint256)", erc20, from, to, amount), 0));
  }
  function addTransferFromERC20CallLimited(uint256 erc20Num, uint256 fromNum, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferFromERC20(address,address,address,uint256)", erc20NumToAddress(erc20Num), dSafeNumToAddress(fromNum), dSafeNumToAddress(toNum), amount), 0));
  }

  function addTransferFromERC721Call(address erc721, address from, address to, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferFromERC721(address,address,address,uint256)", erc721, from, to, tokenId), 0));
  }
  function addTransferFromERC721CallLimited(uint256 erc721Num, uint256 fromNum, uint256 toNum, uint256 tokenId) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferFromERC721(address,address,address,uint256)", erc721NumToAddress(erc721Num), dSafeNumToAddress(fromNum), dSafeNumToAddress(toNum), tokenId), 0));
  }

  function addOnERC721ReceivedCall(address operator, address from, uint256 tokenId, bytes calldata data) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", operator, from, tokenId, data), 0));
  }
  function addOnERC721ReceivedCallLimited(address operator, uint256 fromNum, uint256 tokenId, bytes calldata data) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", operator, dSafeNumToAddress(fromNum), tokenId, data), 0));
  }

  function addDepositERC20ForSafeCall(address erc20, address to, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC20ForSafe(address,address,uint256)", erc20, to, amount), 0));
  }
  function addDepositERC20ForSafeCallLimited(uint256 erc20Num, uint256 toNum, uint256 amount) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("depositERC20ForSafe(address,address,uint256)", erc20NumToAddress(erc20Num), dSafeNumToAddress(toNum), amount), 0));
  }

  function addLiquidateCall(address dSafe) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("liquidate(address)", dSafe), 0));
  }
  function addLiquidateCallLimited(uint256 dSafeNum) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("liquidate(address)", dSafeNumToAddress(dSafeNum)), 0));
  }

  function addUpgradeDSafeImplementationCall(string calldata version) public {
    uint256 numPaddingBytes = 32 - (bytes(version).length % 32);
    if (numPaddingBytes == 32) numPaddingBytes = 0;
    calls.push(Call(address(dos), abi.encodeWithSignature("upgradeDSafeImplementation(string)", version), 0));
  }

  function addTransferDSafeOwnershipCall(address newOwner) public {
    calls.push(Call(address(dos), abi.encodeWithSignature("transferDSafeOwnership(address)", newOwner), 0));
  }

   function create_erc20(bool _weth, string memory name, string memory symbol, uint8 decimals, int256 price, uint256 baseRate, uint256 slope1, uint256 slope2, uint256 targetUtilization) internal returns (address token, MockERC20Oracle oracle) {
      address token;

      if (_weth) {
        token = address(new WETH9());
      } else {
        token = address(new TestERC20(name, symbol, decimals));
      }
      MockERC20Oracle oracle = new MockERC20Oracle(address(this));

      oracle.setPrice(price, 6, uint256(decimals));

      erc20s.push(IERC20(token));

      IDOS(address(dos)).addERC20Info(
      token,
      name,
      symbol,
      decimals,
      address(oracle),
      baseRate,
      slope1,
      slope2,
      targetUtilization
    );
  }

  function create_erc721(string memory name, string memory symbol, uint256 startId, address oracle) internal returns (TestNFT nft) {
    TestNFT nft = new TestNFT(name, symbol, startId);

    erc721s.push(nft);
    IDOS(address(dos)).addERC721Info(address(nft), oracle);
  }

  // we leave out the onlyGovernance functions, since modifer onlyGovernance() is pretty airtight
  // and we check that immutableGovernance hasn't changed in EchidnaDOS.invariant()

  // TODO depositFull, withdrawFull, executeBatch, approveAndCall
  // TODO maybe add uni
  // TODO make it so new erc20s and erc721s can be created at runtime
  // TODO ability to change the price of an erc20 or erc721


  // ******************** Check Proper System Deployment ********************

  function check_proper_deployment() public {
    for(uint256 i; i < erc20s.length; i++) {
      (address tokenAddress,,,,,,,,) = dos.erc20Infos(i);

      assert(address(erc20s[i]) != address(0));
      assert(address(erc20s[i]) == tokenAddress);
    }

    for(uint256 i; i < erc721s.length; i++) {
      (address tokenAddress,) = dos.erc721Infos(i);

      assert(address(erc721s[i]) != address(0));
      assert(address(erc721s[i]) == tokenAddress);
    }

    for (uint256 i; i < dSafes.length; i++) {
      assert(address(dSafes[i]) != address(0));
    }

    assert(address(dos) != address(0));
  }

  // ******************** Simple invariants ********************

  function depositERC20_never_reverts(uint256 erc20Index, uint256 amount) public {
    uint256 index = erc20Index % erc20s.length;
    IERC20 erc20 = erc20s[index];
    Call[] memory approveAndDeposit = new Call[](1);
    approveAndDeposit[0] = Call(address(erc20), abi.encodeWithSignature("approve(address,uint256)", address(dos), amount),0);
    approveAndDeposit[1] = Call(address(dos), bytes.concat(methodSigBytes("depositERC20(address,uint256)"),addrToBytes(address(erc20)),bytes32(amount)), 0);

    if (erc20.balanceOf(address(selectedProxy)) >= amount && amount > 0 && int256(amount) > 0) {
      try selectedProxy.executeBatch(approveAndDeposit) {} catch {
        assert(false);
      }
      int256 balance = dosConfig.getDAccountERC20(address(selectedProxy), erc20);
      assert(balance > 0);
      assert(uint256(balance) == amount);
    }
  }

}

contract EchidnaDOS is DOS {
  constructor(address _dosConfig, address _versionManager) DOS(_dosConfig, _versionManager) {}
  function invariant() public returns (bool) {

    // check 1: governance hasn't changed
    if (DOSConfig(address(this)).immutableGovernance() != msg.sender)
      return false; // msg.sender will always be EchidnaDOSTests

    // check 2: global solvency checks
    // largely copied from isSolvent
    uint256 gasBefore = gasleft();
    int256 leverage = config.fractionalReserveLeverage;
    for (uint256 i = 0; i < erc20Infos.length; i++) {
      int256 totalDebt = erc20Infos[i].debt.tokens;
      int256 totalCollateral = erc20Infos[i].collateral.tokens;

      if (totalDebt > 0) return false;
      if (totalCollateral < 0) return false;

      int256 reserve = totalCollateral + totalDebt;

      if (
        IERC20(erc20Infos[i].erc20Contract).balanceOf(address(this)) < uint256(reserve)
      ) return false;

      if (reserve < -totalDebt / leverage) return false;
    }
    if (gasBefore - gasleft() > config.maxSolvencyCheckGasCost) return false;

    // more rules can be added here

    return true;
  }
}

// can add more of these contracts if you want invariants on more contracts
pragma solidity ^0.8.17;

import {DSafeProxy} from "../../dos/DSafeProxy.sol";
import "../../lib/Call.sol";
import "../../interfaces/IDOS.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

library Helpers {

  function getDepositERC20Call(address receiver, address erc20, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("depositERC20(address,uint256)", erc20, amount), 0);
  }

  function getDepositERC721Call(address receiver, address erc721, uint256 tokenId) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("depositERC721(address,uint256)", erc721, tokenId), 0);
  }

  function getWithdrawERC20Call(address receiver, address erc20, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("withdrawERC20(address,uint256)", erc20, amount), 0);
  }

  function getWithdrawERC721Call(address receiver, address erc721, uint256 tokenId) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("withdrawERC721(address,uint256)", erc721, tokenId), 0);
  }

  function getTransferERC20Call(address receiver, address erc20, address to, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("transferERC20(address,address,uint256)", erc20, to, amount), 0);
  }

  function getTransferERC721Call(address receiver, address erc721, uint256 tokenId, address to) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("transferERC721(address,uint256,address)", erc721, tokenId, to), 0);
  }

  function getTransferFromERC20Call(address receiver, address erc20, address from, address to, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("transferFromERC20(address,address,address,uint256)", erc20, from, to, amount), 0);
  }

  function getTransferFromERC721Call(address receiver, address erc721, address from, address to, uint256 tokenId) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("transferFromERC721(address,address,address,uint256)", erc721, from, to, tokenId), 0);
  }

  function getOnERC721ReceivedCall(address receiver, address operator, address from, uint256 tokenId, bytes calldata data) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", operator, from, tokenId, data), 0);
  }

  function getDepositERC20ForSafeCall(address receiver, address erc20, address to, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("depositERC20ForSafe(address,address,uint256)", erc20, to, amount), 0);
  }

  function getLiquidateCall(address receiver, address dSafe) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("liquidate(address)", dSafe), 0);
  }

  function getUpgradeDSafeImplementationCall(address receiver, string calldata version) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("upgradeDSafeImplementation(string)", version), 0);
  }

  function getTransferDSafeOwnershipCall(address receiver, address newOwner) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("transferDSafeOwnership(address)", newOwner), 0);
  }

  function getApproveCall(address receiver, address to, uint256 amount) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("approve(address,uint256)", to, amount), 0);
  }

  function getDepositFullCall(address receiver, address[] memory erc20s) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("depositFull(address[])", erc20s), 0);
  }

  function getWithdrawFullCall(address receiver, address[] memory erc20s) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("withdrawFull(address[])", erc20s), 0);
  }

  function getApproveAndCallCall(address receiver, IDOSCore.Approval[] memory approvals, address spender, bytes calldata data) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("approveAndCall((address,uint256)[],address,bytes)", approvals, spender, data), 0);
  }

  function getExecuteBatchCall(address receiver, Call[] calldata calls) internal pure returns (Call memory) {
    return Call(receiver, abi.encodeWithSignature("executeBatch((address,bytes,uint256)[])", calls), 0);
  }
}

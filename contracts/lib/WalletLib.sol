// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC20Share, NFTTokenData} from "../interfaces/ISupa.sol";
import {FsMath} from "../lib/FsMath.sol";

library WalletLib {
    type NFTId is uint256; // 16 bits (tokenId) + 224 bits (hash) + 16 bits (erc721 index)

    /// @notice NFT must be in the user's wallet
    error NFTNotInWallet();

    struct Wallet {
        address owner;
        int256 tokenCounter;
        mapping(uint16 => ERC20Share) erc20Share;
        NFTId[] nfts;
        // bitmask of Supa indexes of ERC20 present in a wallet. `1` can be increased on updates
        uint256[1] creditAccountErc20Idxs;
    }

    function removeERC20IdxFromCreditAccount(Wallet storage wallet, uint16 erc20Idx) internal {
        wallet.creditAccountErc20Idxs[erc20Idx >> 8] &= ~(1 << (erc20Idx & 255));
        --wallet.tokenCounter;
    }

    function addERC20IdxToCreditAccount(Wallet storage wallet, uint16 erc20Idx) internal {
        wallet.creditAccountErc20Idxs[erc20Idx >> 8] |= (1 << (erc20Idx & 255));
        ++wallet.tokenCounter;
    }

    function extractNFT(
        Wallet storage wallet,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = map[nftId].walletIdx;
        map[nftId].approvedSpender = address(0); // remove approval
        bool userOwnsNFT = wallet.nfts.length > 0 &&
            NFTId.unwrap(wallet.nfts[idx]) == NFTId.unwrap(nftId);
        if (!userOwnsNFT) {
            revert NFTNotInWallet();
        }
        if (idx == wallet.nfts.length - 1) {
            wallet.nfts.pop();
        } else {
            NFTId lastNFTId = wallet.nfts[wallet.nfts.length - 1];
            map[lastNFTId].walletIdx = idx;
            wallet.nfts[idx] = lastNFTId;
            wallet.nfts.pop();
        }
    }

    function insertNFT(
        Wallet storage wallet,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = uint16(wallet.nfts.length);
        wallet.nfts.push(nftId);
        map[nftId].walletIdx = idx;
    }

    function getERC20s(Wallet storage wallet) internal view returns (uint16[] memory erc20s) {
        uint256 numberOfERC20 = 0;
        for (uint256 i = 0; i < wallet.creditAccountErc20Idxs.length; i++) {
            numberOfERC20 += FsMath.bitCount(wallet.creditAccountErc20Idxs[i]);
        }
        erc20s = new uint16[](numberOfERC20);
        uint256 idx = 0;
        for (uint256 i = 0; i < wallet.creditAccountErc20Idxs.length; i++) {
            uint256 mask = wallet.creditAccountErc20Idxs[i];
            for (uint256 j = 0; j < 256; j++) {
                uint256 x = mask >> j;
                if (x == 0) break;
                if ((x & 1) != 0) {
                    erc20s[idx++] = uint16(i * 256 + j);
                }
            }
        }
    }
}

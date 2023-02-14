// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC20Share, NFTTokenData} from "../interfaces/IDOS.sol";
import {FsMath} from "../lib/FsMath.sol";

library DSafeLib {
    type NFTId is uint256; // 16 bits (tokenId) + 224 bits (hash) + 16 bits (erc721 index)

    /// @notice NFT must be in the user's dSafe
    error NFTNotInDSafe();

    struct DSafe {
        address owner;
        mapping(uint16 => ERC20Share) erc20Share;
        NFTId[] nfts;
        // bitmask of DOS indexes of ERC20 present in a dSafe. `1` can be increased on updates
        uint256[1] dAccountErc20Idxs;
    }

    function removeERC20IdxFromDAccount(DSafe storage dSafe, uint16 erc20Idx) internal {
        dSafe.dAccountErc20Idxs[erc20Idx >> 8] &= ~(1 << (erc20Idx & 255));
    }

    function addERC20IdxToDAccount(DSafe storage dSafe, uint16 erc20Idx) internal {
        dSafe.dAccountErc20Idxs[erc20Idx >> 8] |= (1 << (erc20Idx & 255));
    }

    function extractNFT(
        DSafe storage dSafe,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = map[nftId].dSafeIdx;
        map[nftId].approvedSpender = address(0); // remove approval
        bool userOwnsNFT = dSafe.nfts.length > 0 &&
            NFTId.unwrap(dSafe.nfts[idx]) == NFTId.unwrap(nftId);
        if (!userOwnsNFT) {
            revert NFTNotInDSafe();
        }
        if (idx == dSafe.nfts.length - 1) {
            dSafe.nfts.pop();
        } else {
            NFTId lastNFTId = dSafe.nfts[dSafe.nfts.length - 1];
            map[lastNFTId].dSafeIdx = idx;
            dSafe.nfts[idx] = lastNFTId;
            dSafe.nfts.pop();
        }
    }

    function insertNFT(
        DSafe storage dSafe,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = uint16(dSafe.nfts.length);
        dSafe.nfts.push(nftId);
        map[nftId].dSafeIdx = idx;
    }

    function getERC20s(DSafe storage dSafe) internal view returns (uint16[] memory erc20s) {
        uint256 numberOfERC20 = 0;
        for (uint256 i = 0; i < dSafe.dAccountErc20Idxs.length; i++) {
            numberOfERC20 += FsMath.bitCount(dSafe.dAccountErc20Idxs[i]);
        }
        erc20s = new uint16[](numberOfERC20);
        uint256 idx = 0;
        for (uint256 i = 0; i < dSafe.dAccountErc20Idxs.length; i++) {
            uint256 mask = dSafe.dAccountErc20Idxs[i];
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

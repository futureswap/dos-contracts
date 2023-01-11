// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

struct NonceMap {
    mapping(uint256 => uint256) nonceBitmap;
}

library NonceMapLib {
    function validateAndUseNonce(NonceMap storage self, uint256 nonce) internal {
        require(self.nonceBitmap[nonce >> 8] & (1 << (nonce & 0xff)) == 0, "Nonce already used");
        self.nonceBitmap[nonce >> 8] |= (1 << (nonce & 0xff));
    }

    function getNonce(NonceMap storage self, uint256 nonce) internal view returns (bool) {
        return self.nonceBitmap[nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }
}

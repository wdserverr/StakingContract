// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;


interface IERCLazyMint {

    struct TierCost {
        uint256 costEth;
        uint256 costToken;
    }
    struct TierMaxSupply {
        uint256 supply;
    }
}

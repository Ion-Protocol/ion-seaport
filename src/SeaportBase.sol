// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

contract SeaportBase {
    error DeleverageMustBeInitiated();

    uint8 ILK_INDEX = 0; 

    uint256 internal constant TSLOT_AWAIT_CALLBACK = 0;
    uint256 internal constant TSLOT_COLLATERAL_DELTA = 1;
    uint256 internal constant TSLOT_WHITELIST_PROOF = 2;

     modifier onlyReentrant() {
        uint256 deleverageInitiated;

        assembly {
            deleverageInitiated := tload(TSLOT_AWAIT_CALLBACK)
        }

        if (deleverageInitiated == 0) revert DeleverageMustBeInitiated();
        _;
    }
}
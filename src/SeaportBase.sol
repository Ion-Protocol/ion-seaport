// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { IWhitelist } from "./interfaces/IWhitelist.sol";

contract SeaportBase {
    error DeleverageMustBeInitiated();

    uint256 internal constant TSLOT_AWAIT_CALLBACK = 0;
    uint256 internal constant TSLOT_COLLATERAL_DELTA = 1;
    uint256 internal constant TSLOT_WHITELIST_PROOF = 2;

    uint8 ILK_INDEX = 0;

    IIonPool public immutable POOL;
    IGemJoin public immutable JOIN;
    IWhitelist public immutable WHITELIST;

    IERC20 public immutable BASE;
    IERC20 public immutable COLLATERAL;

    modifier onlyReentrant() {
        uint256 deleverageInitiated;

        assembly {
            deleverageInitiated := tload(TSLOT_AWAIT_CALLBACK)
        }

        if (deleverageInitiated == 0) revert DeleverageMustBeInitiated();
        _;
    }

    /**
     * @notice Only allows whitelisted borrowers to use this contract.
     * @dev This contract will be a part of `protocolWhitelist`, so all
     * calls made from this contract to the IonPool as the sender will
     * succeed. This contract verifies the whitelist proof on its own
     * in order to avoid having to pass the proof through the callbacks
     * and to the IonPool.
     * @param proof Merkle path for the whitelist root.
     */
    modifier onlyWhitelistedBorrowers(bytes32[] memory proof) {
        WHITELIST.isWhitelistedBorrower(ILK_INDEX, msg.sender, msg.sender, proof);
        _;
    }

    constructor(IIonPool pool, IGemJoin gemJoin, uint8 ilkIndex) {
        POOL = pool;
        JOIN = gemJoin;
        ILK_INDEX = ilkIndex;

        BASE = IERC20(pool.underlying());
        COLLATERAL = IERC20(gemJoin.GEM());
    }
}

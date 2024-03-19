// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {SeaportBase} from "./SeaportBase.sol";

import {IIonPool} from "./interfaces/IIonPool.sol";
import {IGemJoin} from "./interfaces/IGemJoin.sol";

import { Order, OrderParameters, OfferItem, ConsiderationItem } from "seaport-types/src/lib/ConsiderationStructs.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";

import {WadRayMath} from "ion-protocol/src/libraries/math/WadRayMath.sol";
contract SeaportLeverage is SeaportBase {
    using WadRayMath for uint256;

    IIonPool public immutable POOL;
    IGemJoin public immutable JOIN;

    SeaportInterface public constant SEAPORT = SeaportInterface(0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC);

    uint256 internal constant TSLOT_INITIAL_DEPOSIT = 3; 
    uint256 internal constant TSLOT_WHITELIST_ARRAY_START = 4; 

    constructor(IIonPool pool, IGemJoin gemJoin, uint8 ilkIndex) {
        POOL = pool; 
        JOIN = gemJoin;
    }

    function leverage(Order calldata order, uint256 initialDeposit, 
    uint256 resultingAdditionalCollateral, uint256 maxResultingDebt, 
    bytes32[] memory proof) external {
       
        assembly {
            tstore(TSLOT_AWAIT_CALLBACK, 1)
            tstore(TSLOT_COLLATERAL_DELTA, resultingAdditionalCollateral)
            tstore(TSLOT_INITIAL_DEPOSIT, initialDeposit)
        }

        SEAPORT.fulfillOrder(order, bytes32(0)); 

        assembly {
            tstore(TSLOT_AWAIT_CALLBACK, 0)
            tstore(TSLOT_COLLATERAL_DELTA, 0) 
            tstore(TSLOT_INITIAL_DEPOSIT, 0) 
        }
    }

    /**
     * initialCollateral
     * resultingAdditionalCollateral
     * 
     * 
     * Receive the collateral from offerer, make a deposit. 
     * Borrow from the IonPool to pay the seaport consideration. 
     */
    function seaportCallback(address, address user, uint256 borrowAmount) external {

        uint256 initialDeposit;  
        uint256 additionalCollateral;
        assembly {
            initialDeposit := tload(TSLOT_INITIAL_DEPOSIT)
            additionalCollateral := tload(TSLOT_COLLATERAL_DELTA)
            proof := tload(TSLOT_WHITELIST_PROOF)
        }
        uint256 totalDeposit = initialDeposit + additionalCollateral; 

        // uint256 totalDeposit; TODO: check gas savings 
        // assembly {
        //     initialDeposit := tload(TSLOT_INITIAL_DEPOSIT)
        //     additionalCollateral := tload(TSLOT_COLLATERAL_DELTA) 
              
        //     let sum := add(initialDeposit, additionalCollateral)
            
        //     if or(iszero(lt(sum, initialDeposit)), iszero(lt(sum, additionalCollateral))) {
        //         // Revert if overflow occurred
        //         revert(0, 0)
        //     }
        //     totalDeposit := sum
        // }

        // borrowAmount and totalDeposit that aimed too close to max leverage
        // may revert on UnsafePositionChange if the runtime debt is higher 
        // than expected at the time of generating the signature. 

        uint256 currentRate = POOL.rate(ILK_INDEX);
        uint256 borrowAmountNormalized = borrowAmount.rayDivDown(currentRate); 

        // deposit combined collateral 
        JOIN.join(address(this), totalDeposit); 
        POOL.depositCollateral(ILK_INDEX, user, address(this), totalDeposit, new bytes32[](0));
        POOL.borrow(ILK_INDEX, user, address(this), borrowAmountNormalized, new bytes32[](0)); 
    }

}
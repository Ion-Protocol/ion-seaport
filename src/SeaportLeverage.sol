// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { SeaportBase } from "./SeaportBase.sol";

import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";

import {
    Order,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";

import { WadRayMath } from "ion-protocol/src/libraries/math/WadRayMath.sol";

contract SeaportLeverage is SeaportBase {
    using WadRayMath for uint256;

    SeaportInterface public constant SEAPORT = SeaportInterface(0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC);

    uint256 internal constant TSLOT_INITIAL_DEPOSIT = 3;
    uint256 internal constant TSLOT_WHITELIST_ARRAY_START = 4;

    // Offer item validation, the collateral asset is being offered
    error OItemTypeMustBeERC20(ItemType itemType);
    error OTokenMustBeCollateral(address token);
    error OStartMustBeCollateralToPurchase(uint256 startAmount, uint256 collateralToPurchase);
    error OEndMustBeCollateralToPurchase(uint256 endAmount, uint256 collateralToPurchase);

    // Consideration item 1 validation, only used as a callback
    error C1TypeMustBeERC20(ItemType itemType);
    error C1TokenMustBeThis(address token);
    error C1StartAmountMustBeAmountToBorrow(uint256 startAmount, uint256 amountToBorrow);
    error C1EndAmountMustBeAmountToBorrow(uint256 endAmount, uint256 amountToBorrow);
    error C1RecipientMustBeSender(address recipient);

    // Consideration item 2 validation, the base asset is beign paid for the offer
    error C2TypeMustBeERC20(ItemType itemType);
    error C2TokenMustBeBase(address token);
    error C2StartMustBeAmountToBorrow(uint256 startAmount, uint256 amountToBorrow);
    error C2EndMustBeAmountToBorrow(uint256 endAmount, uint256 amountToBorrow);

    constructor(IIonPool pool, IGemJoin gemJoin, uint8 ilkIndex) SeaportBase(pool, gemJoin, ilkIndex) { }

    function leverage(
        Order calldata order,
        uint256 initialDeposit,
        uint256 resultingAdditionalCollateral,
        uint256 amountToBorrow,
        bytes32[] memory proof
    )
        external
        onlyWhitelistedBorrowers(proof)
    {
        uint256 collateralToPurchase = resultingAdditionalCollateral - initialDeposit;
        OrderParameters calldata params = order.parameters;

        OfferItem calldata offer1 = params.offer[0];

        // offer asset is the collateral asset, consideration asset is the base asset
        if (offer1.token != address(COLLATERAL)) revert OTokenMustBeCollateral(offer1.token);
        if (offer1.startAmount != collateralToPurchase) {
            revert OStartMustBeCollateralToPurchase(offer1.startAmount, collateralToPurchase);
        }
        if (offer1.endAmount != collateralToPurchase) {
            revert OEndMustBeCollateralToPurchase(offer1.endAmount, collateralToPurchase);
        }

        ConsiderationItem calldata consideration1 = params.consideration[0];

        // forgefmt: disable-start
        if (consideration1.itemType != ItemType.ERC20) 
            revert C1TypeMustBeERC20(consideration1.itemType);
        if (consideration1.token != address(this)) 
            revert C1TokenMustBeThis(consideration1.token);
        if (consideration1.startAmount != amountToBorrow) 
            revert C1StartAmountMustBeAmountToBorrow(consideration1.startAmount, amountToBorrow);
        if (consideration1.endAmount != amountToBorrow) 
            revert C1EndAmountMustBeAmountToBorrow(consideration1.endAmount, amountToBorrow);
        if (consideration1.recipient != msg.sender) 
            revert C1RecipientMustBeSender(msg.sender);

        ConsiderationItem calldata consideration2 = params.consideration[1];
        
        if (consideration2.itemType != ItemType.ERC20) 
            revert C2TypeMustBeERC20(consideration2.itemType);
        if (consideration2.token != address(BASE)) 
            revert C2TokenMustBeBase(consideration2.token);
        if (consideration2.startAmount != amountToBorrow) 
            revert C2StartMustBeAmountToBorrow(consideration2.startAmount, amountToBorrow);
        if (consideration2.endAmount != amountToBorrow) 
            revert C2EndMustBeAmountToBorrow(consideration2.endAmount, amountToBorrow);
        // forgefmt: disable-end

        assembly {
            tstore(TSLOT_AWAIT_CALLBACK, 1)
            // just store total deposit amount and not both
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
     * Receive the collateral from offerer, make a deposit.
     * Borrow from the IonPool to pay the seaport consideration.
     */
    function seaportCallback(address, address user, uint256 amountToBorrow) external {
        uint256 initialDeposit;
        uint256 additionalCollateral;
        assembly {
            initialDeposit := tload(TSLOT_INITIAL_DEPOSIT)
            additionalCollateral := tload(TSLOT_COLLATERAL_DELTA)
        }

        uint256 totalDeposit = initialDeposit + additionalCollateral;

        // `borrowAmount` and `totalDeposit` that aim too close to max leverage
        // may revert on UnsafePositionChange if the runtime debt is higher
        // than expected at the time of generating the signature.

        uint256 currentRate = POOL.rate(ILK_INDEX);
        uint256 borrowAmountNormalized = amountToBorrow.rayDivDown(currentRate);

        // deposit combined collateral
        JOIN.join(address(this), totalDeposit);
        POOL.depositCollateral(ILK_INDEX, user, address(this), totalDeposit, new bytes32[](0));
        POOL.borrow(ILK_INDEX, user, address(this), borrowAmountNormalized, new bytes32[](0));
    }
}

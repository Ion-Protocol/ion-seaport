// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { SeaportBase } from "./SeaportBase.sol";

import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { IWhitelist } from "./interfaces/IWhitelist.sol";
import {
    Order,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { WadRayMath } from "ion-protocol/src/libraries/math/WadRayMath.sol";

import { console2 } from "forge-std/console2.sol";

contract SeaportLeverage is SeaportBase {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    uint256 internal constant TSLOT_RESULTING_ADDITIONAL_COLLATERAL = 2;

    IWhitelist public immutable WHITELIST;

    // Offer item validation, the collateral asset is being offered
    error OTokenMustBeCollateral(address token);
    error OStartMustBeCollateralToPurchase(uint256 startAmount, uint256 collateralToPurchase);
    error OEndMustBeCollateralToPurchase(uint256 endAmount, uint256 collateralToPurchase);

    // Consideration item 1 validation, only used as a callback
    error C1StartAmountMustBeAmountToBorrow(uint256 startAmount, uint256 amountToBorrow);
    error C1EndAmountMustBeAmountToBorrow(uint256 endAmount, uint256 amountToBorrow);

    // Consideration item 2 validation, the base asset is beign paid for the offer
    error C2TokenMustBeBase(address token);
    error C2StartMustBeAmountToBorrow(uint256 startAmount, uint256 amountToBorrow);
    error C2EndMustBeAmountToBorrow(uint256 endAmount, uint256 amountToBorrow);

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

    constructor(
        IIonPool pool,
        IGemJoin gemJoin,
        uint8 ilkIndex,
        IWhitelist whitelist
    )
        SeaportBase(pool, gemJoin, ilkIndex)
    {
        WHITELIST = whitelist;

        // The IonPool takes the initial deposit collateral from
        // the caller and seaport takes base asset from the offerer.
        BASE.approve(address(SEAPORT), type(uint256).max);
        COLLATERAL.approve(address(POOL), type(uint256).max);
        COLLATERAL.approve(address(JOIN), type(uint256).max);
    }

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
        // transfer initial collateral to this contract
        uint256 collateralToPurchase = resultingAdditionalCollateral - initialDeposit;
        COLLATERAL.safeTransferFrom(msg.sender, address(this), initialDeposit);

        OrderParameters calldata params = order.parameters;

        _validateOrderParams(params);

        OfferItem calldata offer1 = params.offer[0];

        // offer asset is the collateral asset, consideration asset is the base asset
        if (offer1.itemType != ItemType.ERC20) revert OItemTypeMustBeERC20(offer1.itemType);
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
        console2.log('msg sender', msg.sender);
        console2.log('recipient', consideration1.recipient);
        if (consideration1.recipient != msg.sender) // TODO: does this matter? or is it just overconstraint?
            revert C1RecipientMustBeSender(consideration1.recipient);

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
            tstore(TSLOT_RESULTING_ADDITIONAL_COLLATERAL, resultingAdditionalCollateral)
        }

        SEAPORT.fulfillOrder(order, bytes32(0));

        assembly {
            tstore(TSLOT_AWAIT_CALLBACK, 0)
            tstore(TSLOT_RESULTING_ADDITIONAL_COLLATERAL, 0)
        }
    }

    /**
     * initialCollateral
     * resultingAdditionalCollateral
     * Receive the collateral from offerer, make a deposit.
     * Borrow from the IonPool to pay the seaport consideration.
     */
    function seaportCallback4878572495(
        address,
        address user,
        uint256 amountToBorrow
    )
        external
        onlySeaport
        onlyReentrant
    {
        uint256 resultingAdditionalCollateral;
        assembly {
            resultingAdditionalCollateral := tload(TSLOT_RESULTING_ADDITIONAL_COLLATERAL)
        }

        // `borrowAmount` and `totalDeposit` that aim too close to max leverage
        // may revert on UnsafePositionChange if the runtime debt is higher
        // than expected at the time of generating the signature.

        uint256 currentRate = POOL.rate(ILK_INDEX);

        // get normalized amount such that the resulting borrowed amount is exactly `amountToBorrow`
        // changeInDebt = changeInNormalizedDebt * rate
        // transferAmt = changeInDebt / RAY
        // this transferAmt must be `amountToBorrow`
        uint256 amountToBorrowNormalized = amountToBorrow.rayDivUp(currentRate);

        // deposit combined collateral
        JOIN.join(address(this), resultingAdditionalCollateral);
        POOL.depositCollateral(ILK_INDEX, user, address(this), resultingAdditionalCollateral, new bytes32[](0));
        POOL.borrow(ILK_INDEX, user, address(this), amountToBorrowNormalized, new bytes32[](0));
    }
}

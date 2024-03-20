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

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { WadRayMath } from "ion-protocol/src/libraries/math/WadRayMath.sol";

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

    /**
     * @notice Leverage a position on `IonPool` through Seaport.
     *
     * @dev
     * ```solidity
     * struct Order {
     *      OrderParameters parameters;
     *      bytes signature;
     * }
     *
     * struct OrderParameters {
     *      address offerer; // 0x00
     *      address zone; // 0x20
     *      OfferItem[] offer; // 0x40
     *      ConsiderationItem[] consideration; // 0x60
     *      OrderType orderType; // 0x80
     *      uint256 startTime; // 0xa0
     *      uint256 endTime; // 0xc0
     *      bytes32 zoneHash; // 0xe0
     *      uint256 salt; // 0x100
     *      bytes32 conduitKey; // 0x120
     *      uint256 totalOriginalConsiderationItems; // 0x140
     * }
     *
     *
     * struct OfferItem {
     *      ItemType itemType;
     *      address token;
     *      uint256 identifierOrCriteria;
     *      uint256 startAmount;
     *      uint256 endAmount;
     * }
     *
     * struct ConsiderationItem {
     *      ItemType itemType;
     *      address token;
     *      uint256 identifierOrCriteria;
     *      uint256 startAmount;
     *      uint256 endAmount;
     *      address payable recipient;
     * }
     * ```
     *
     * REQUIRES:
     * - There should only be one token for the `Offer`.
     * - There should be two items in the `Consideration`.
     * - The `zone` must be this contract's address.
     * - The `orderType` must be `FULL_RESTRICTED`. This means only the `zone`,
     * or the offerer, can fulfill the order.
     * - The `conduitKey` must be zero. No conduit should be used.
     * - The `totalOriginalConsiderationItems` must be 2.
     *
     * - The `Offer` item must be of type `ERC20`.
     * - For the case of leverage, `token` of the `Offer` item must be the
     * `COLLATERAL` token.
     * - The `startAmount` and `endAmount` of the `Offer` item must be equal to
     * `collateralToPurchase`. Start and end should be equal because the amount is fixed.
     *
     * - The first `Consideration` item must be of type `ERC20`.
     * - The `token` of the first `Consideration` item must be this contract's
     * address. This is to allow this contract to gain control flow. We also
     * want to use the `transferFrom()` args to communicate data to the
     * `transferFrom()` callback. Any data that can't be fit into the
     * `transferFrom()` args will be communicated through transient storage.
     * - The `startAmount` and `endAmount` of the first `Consideration` item
     * communicate the amount of `BASE` asset to borrow from the IonPool during
     * the callback.
     * - The `recipient` of the first `Consideration` item must be `msg.sender`.
     * This will be user's vault that will be deleveraged. This contract assumes
     * that caller is the owner of the vault.
     *
     * - The second `Consideration` item must be of type `ERC20`.
     * - The `token` of the second `Consideration` item must be the `BASE`
     * - The second `Consideration` item must have the `startAmount` and `endAmount`
     * equal to `amountToBorrow`.
     *
     * We don't constrain the `recipient` of the second `Consideration` item.
     *
     * It is technically possible for two distinct orders to have the same
     * parameters. The `salt` should be used to distinguish between two orders
     * with the same parameters. Otherwise, they will map to the same order hash
     * and only one of them will be able to be fulfilled.
     *
     * @param order Seaport order.
     * @param initialDeposit Amount of collateral to be transferred from sender. [WAD]
     * @param resultingAdditionalCollateral Total collateral to be deposited from this call. [WAD]
     * @param amountToBorrow Amount of base asset to borrow. [WAD]
     * @param proof Merkle path for the whitelist root.
     */
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
        if (consideration1.recipient != msg.sender)
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

        // Gets the normalized amount such that the reuslting borrowed amount is at least `amountToBorrow`.
        // This may create dust amounts of additional debt than intended.
        uint256 amountToBorrowNormalized = amountToBorrow.rayDivUp(currentRate);

        JOIN.join(address(this), resultingAdditionalCollateral);
        POOL.depositCollateral(ILK_INDEX, user, address(this), resultingAdditionalCollateral, new bytes32[](0));
        POOL.borrow(ILK_INDEX, user, address(this), amountToBorrowNormalized, new bytes32[](0));
    }
}

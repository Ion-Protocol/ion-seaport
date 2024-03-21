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


/**
 * @title Seaport Leverage
 * @notice A contract to leverage a position on Ion Protocol using RFQ swaps
 * facilitated by Seaport.
 *
 * @dev The standard Seaport flow would go as follows:
 *
 *      1. An `offerrer` creates an `Order` and signs it. The `fulfiller` will
 *      be given both the `Order` payload and the `signature`. The `fulfiller`'s
 *      role is to execute the transaction.
 *
 *      Inside an `Order`, there is
 *       - an `offerer`: the signature that will be `ecrecover()`ed to verify
 *       the integrity of the signature.
 *       - an array of `Offer`s: Each `Offer` will have a token and an amount.
 *       - an array of `Consideration`s: Each `Consideration` will have a token,
 *       an amount and a recipient.
 *
 *      2. Seaport will verify the signature was signed by the `offerer`.
 *
 *      3. Seaport will iterate through all the `Offer`s and transfer the
 *      specified amount of each token to the fulfiller from the offerer.
 *
 *      4. Seaport will iterate through all the `Consideration`s and transfer
 *      the specified amount of each token from the fulfiller to the recipient.
 *
 * For the leverage and deleverage use-case, it is unideal that steps 3 and 4 must happen
 * in order because it means `Offer` items cannot be used before satisfying
 * `Consideration` constraints. In a leverage case, the user requires access
 * to the additionally purchased collateral before taking out a loan from the 
 * IonPool to pay the offerer. This requires Seaport to first transfer the `BASE` 
 * asset to the user, give control flow to user who can then take out additional 
 * loan from the purchased collateral, then trasnfer the newly borrowed `BASE` 
 * from the user to pay the offerer. 
 * 
 * While this would not be possible in the standard Seaport flow, we engage in a
 * non-standard flow that hijacks the ERC20 `transferFrom()` to gain control
 * flow in between steps 3 and 4. Normally, if the `offerer` wanted to sign for
 * a trade between 100 Token A and 90 Token B, the `Order` payload would contain
 * an `Offer` of 100 Token A and a `Consideration` of 90 Token B to the
 * `offerer`'s address.
 *
 * However, to sign for the same trade to be executed through this contract, the
 * `Order` payload would still contain an `Offer` of 100 Token A. However, the
 * first `Consideration` would pass this contract address as the token address
 * (and the amount would be used to pass some other data) and the second
 * `Consideration` would pass the aforementioned 90 Token B to the `offerer`'s
 * address.
 *
 * This allows this contract to gain control flow in between steps 3 and 4
 * through the `transferFrom()` function and Seaport still enforces the
 * `constraints` of the other `Consideration`s ensuring counterparty's terms.
 */
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

    // Consideration item 2 validation, the base asset is being paid to the offerer
    error C2TokenMustBeBase(address token);
    error C2StartMustBeAmountToBorrow(uint256 startAmount, uint256 amountToBorrow);
    error C2EndMustBeAmountToBorrow(uint256 endAmount, uint256 amountToBorrow);

    error ZeroLeverageAmount(); 

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

        // Seaport takes base asset from the offerer.
        BASE.approve(address(SEAPORT), type(uint256).max);

        // Gemjoin takes the collateral asset from this contract. 
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
        uint256 collateralToPurchase = resultingAdditionalCollateral - initialDeposit;

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
        
        // Consider a case where the recipient is not a msg.sender. The msg.sender can call 
        // this leverage function and specify a different recipient. If that recipient has 
        // added this contract as an operator (if they used this contract before), the msg.sender 
        // can use this contract to manipulate the recipient's vault. We constrain the recipient 
        // and the msg.sender and take away the 'on-behalf-of' functionality to prevent this issue. 
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

        // Seaport does not allow zero swap amounts. 
        if (collateralToPurchase == 0) {
            revert ZeroLeverageAmount(); 
        }

        COLLATERAL.safeTransferFrom(msg.sender, address(this), initialDeposit);

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
     * @notice This callback is triggered by Seaport to give control flow back to this contract. 
     * `borrowAmount` and `totalDeposit` that aim too close to max leverage may revert on 
     * UnsafePositionChange if the runtime debt is higher than expected at the time of generating 
     * the signature.
     * 
     * @dev This function selector has been mined to match the `transferFrom()`
     * selector (`0x23b872dd`). We hijack the `transferFrom()` selector to be
     * able to use the default Seaport flow. This is a callback from Seaport to
     * give this contract control flow between the `Offer` being transferred and
     * the `Consideration` being transferred.
     *
     * In order to enforce that this function is only called through a
     * transaction initiated by this contract, we use the `onlyReentrant`
     * modifier.
     *
     * This function can only be called by the Seaport contract.
     *
     * The second and the third arguments are used to communicate data necessary
     * for the callback context. Transient storage is used to communicate any
     * extra data that could not be fit into the `transferFrom()` args.
     * 
     * @param user Address whose vault is being modified on `IonPool`. 
     * @param amountToBorrow Amount of base asset to borrow. [WAD] 
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

        uint256 currentRate = POOL.rate(ILK_INDEX);

        // Gets the normalized amount such that the reuslting borrowed amount is at least `amountToBorrow`.
        // This may create dust amounts of additional debt than intended.
        uint256 amountToBorrowNormalized = amountToBorrow.rayDivUp(currentRate);

        JOIN.join(address(this), resultingAdditionalCollateral);
        POOL.depositCollateral(ILK_INDEX, user, address(this), resultingAdditionalCollateral, new bytes32[](0));
        POOL.borrow(ILK_INDEX, user, address(this), amountToBorrowNormalized, new bytes32[](0));
    }
}

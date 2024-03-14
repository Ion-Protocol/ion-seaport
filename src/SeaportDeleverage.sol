// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { WadRayMath } from "@ionprotocol/libraries/math/WadRayMath.sol";

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";
import { Order, OrderParameters, OfferItem, ConsiderationItem } from "seaport-types/src/lib/ConsiderationStructs.sol";
import { ItemType, OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";

using WadRayMath for uint256;

contract SeaportDeleverage {
    error InvalidContractConfigs(IIonPool pool, IGemJoin join);
    error DeleverageMustBeInitiated();
    error MsgSenderMustBeSeaport(address msgSender);

    // Order parameters head validation
    error OffersLengthMustBeOne(uint256 length);
    error ConsiderationsLengthMustBeTwo(uint256 length);
    error ZoneMustBeThis(address zone);
    error OrderTypeMustBeFullRestricted(OrderType orderType);
    error ZoneHashMustBeZero(bytes32 zoneHash);
    error ConduitKeyMustBeZero(bytes32 conduitKey);

    // Offer item validation
    error OItemTypeMustBeERC20(ItemType itemType);
    error OTokenMustBeBase(address token);
    error OStartMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error OEndMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);

    // Consideration item 1 validation
    error C1TypeMustBeERC20(ItemType itemType);
    error C1TokenMustBeThis(address token);
    error C1StartAmountMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error C1EndAmountMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);
    error C1RecipientMustBeSender(address recipient);

    // Consideration item 2 validation
    error C2TypeMustBeERC20(ItemType itemType);
    error C2TokenMustBeCollateral(address token);
    error C2StartMustBeCollateralToRemove(uint256 startAmount, uint256 collateralToRemove);
    error C2EndMustBeCollateralToRemove(uint256 endAmount, uint256 collateralToRemove);

    uint256 private constant TSLOT_DELEVERAGE_INITIATED = 0;
    uint256 private constant TSLOT_COLLATERAL_TO_REMOVE = 1;

    SeaportInterface public constant SEAPORT = SeaportInterface(0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC);
    IIonPool public immutable POOL;
    IGemJoin public immutable JOIN;

    IERC20 public immutable BASE;
    IERC20 public immutable COLLATERAL;

    constructor(IIonPool pool, IGemJoin gemJoin) {
        POOL = pool;
        JOIN = gemJoin;

        if (gemJoin.POOL() != address(pool)) {
            revert InvalidContractConfigs(pool, gemJoin);
        }
        if (!pool.hasRole(pool.GEM_JOIN_ROLE(), address(gemJoin))) {
            revert InvalidContractConfigs(pool, gemJoin);
        }

        BASE = IERC20(pool.underlying());
        COLLATERAL = IERC20(gemJoin.GEM());

        BASE.approve(address(SEAPORT), type(uint256).max);
        COLLATERAL.approve(address(SEAPORT), type(uint256).max);
        BASE.approve(address(POOL), type(uint256).max);
    }

    /**
     *
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
     *
     * ```
     *
     * @param order Seaport order.
     * @param collateralToRemove Amount of collateral to remove. [WAD]
     * @param debtToRepay Amount of debt to repay. [WAD]
     */
    function deleverage(Order calldata order, uint256 collateralToRemove, uint256 debtToRepay) external {
        OrderParameters calldata params = order.parameters;

        if (params.offer.length != 1) revert OffersLengthMustBeOne(params.offer.length);
        if (params.consideration.length != 2) revert ConsiderationsLengthMustBeTwo(params.consideration.length);
        if (params.zone != address(this)) revert ZoneMustBeThis(params.zone);
        if (params.orderType != OrderType.FULL_RESTRICTED) revert OrderTypeMustBeFullRestricted(params.orderType);
        if (params.conduitKey != bytes32(0)) revert ConduitKeyMustBeZero(params.conduitKey);

        OfferItem calldata offer1 = params.offer[0];

        if (offer1.itemType != ItemType.ERC20) revert OItemTypeMustBeERC20(offer1.itemType);
        if (offer1.token != address(BASE)) revert OTokenMustBeBase(offer1.token);
        if (offer1.startAmount != debtToRepay) revert OStartMustBeDebtToRepay(offer1.startAmount, debtToRepay);
        if (offer1.endAmount != debtToRepay) revert OEndMustBeDebtToRepay(offer1.endAmount, debtToRepay);

        ConsiderationItem calldata consideration1 = params.consideration[0];

        // forgefmt: disable-start
        if (consideration1.itemType != ItemType.ERC20) 
            revert C1TypeMustBeERC20(consideration1.itemType);
        if (consideration1.token != address(this)) 
            revert C1TokenMustBeThis(consideration1.token);
        if (consideration1.startAmount != debtToRepay) 
            revert C1StartAmountMustBeDebtToRepay(consideration1.startAmount, debtToRepay);
        if (consideration1.endAmount != debtToRepay) 
            revert C1EndAmountMustBeDebtToRepay(consideration1.endAmount, debtToRepay);
        if (consideration1.recipient != msg.sender) 
            revert C1RecipientMustBeSender(msg.sender);

        ConsiderationItem calldata consideration2 = params.consideration[1];
        
        if (consideration2.itemType != ItemType.ERC20) 
            revert C2TypeMustBeERC20(consideration2.itemType);
        if (consideration2.token != address(COLLATERAL)) 
            revert C2TokenMustBeCollateral(consideration2.token);
        if (consideration2.startAmount != collateralToRemove) 
            revert C2StartMustBeCollateralToRemove(consideration2.startAmount, collateralToRemove);
        if (consideration2.endAmount != collateralToRemove) 
            revert C2EndMustBeCollateralToRemove(consideration2.endAmount, collateralToRemove);
        // forgefmt: disable-end

        assembly {
            tstore(TSLOT_DELEVERAGE_INITIATED, 1)
            tstore(TSLOT_COLLATERAL_TO_REMOVE, collateralToRemove)
        }

        SEAPORT.fulfillOrder(order, bytes32(0));

        assembly {
            tstore(TSLOT_DELEVERAGE_INITIATED, 0)
            tstore(TSLOT_COLLATERAL_TO_REMOVE, 0)
        }
    }

    function transferFrom(address, address user, uint256 debtToRepay) external {
        uint256 deleverageInitiated;
        uint256 collateralToRemove;

        assembly {
            deleverageInitiated := tload(TSLOT_DELEVERAGE_INITIATED)
            collateralToRemove := tload(TSLOT_COLLATERAL_TO_REMOVE)
        }

        if (deleverageInitiated == 0) revert DeleverageMustBeInitiated();
        if (msg.sender != address(SEAPORT)) revert MsgSenderMustBeSeaport(msg.sender);

        uint256 currentRate = POOL.rate(0);

        uint256 repayAmountNormalized = debtToRepay.rayDivDown(currentRate);

        POOL.repay(0, user, address(this), repayAmountNormalized);
        POOL.withdrawCollateral(0, user, address(this), collateralToRemove);
        JOIN.exit(address(this), collateralToRemove);
    }
}

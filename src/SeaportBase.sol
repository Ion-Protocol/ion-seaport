// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";
import { ItemType, OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import { OrderParameters } from "seaport-types/src/lib/ConsiderationStructs.sol";

contract SeaportBase {
    error InvalidContractConfigs(IIonPool pool, IGemJoin join);

    // Callback
    error NotACallback();
    error MsgSenderMustBeSeaport(address msgSender);

    // Order parameters head validation
    error OffersLengthMustBeOne(uint256 length);
    error ConsiderationsLengthMustBeTwo(uint256 length);
    error ZoneMustBeThis(address zone);
    error OrderTypeMustBeFullRestricted(OrderType orderType);
    error ZoneHashMustBeZero(bytes32 zoneHash);
    error ConduitKeyMustBeZero(bytes32 conduitKey);
    error InvalidTotalOriginalConsiderationItems();

    // Offer item validation
    error OItemTypeMustBeERC20(ItemType itemType);

    // Consideration item 1 validation
    error C1TypeMustBeERC20(ItemType itemType);
    error C1TokenMustBeThis(address token);
    error C1RecipientMustBeSender(address invalidRecipient);

    // Consideration item 2 validation
    error C2TypeMustBeERC20(ItemType itemType);

    uint256 internal constant TSLOT_AWAIT_CALLBACK = 0;
    uint256 internal constant TSLOT_COLLATERAL_DELTA = 1;

    SeaportInterface public constant SEAPORT = SeaportInterface(0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC);

    uint8 ILK_INDEX = 0;

    IIonPool public immutable POOL;
    IGemJoin public immutable JOIN;

    IERC20 public immutable BASE;
    IERC20 public immutable COLLATERAL;

    modifier onlyReentrant() {
        uint256 deleverageInitiated;

        assembly {
            deleverageInitiated := tload(TSLOT_AWAIT_CALLBACK)
        }

        if (deleverageInitiated == 0) revert NotACallback();
        _;
    }

    modifier onlySeaport() {
        if (msg.sender != address(SEAPORT)) revert MsgSenderMustBeSeaport(msg.sender);
        _;
    }

    constructor(IIonPool pool, IGemJoin gemJoin, uint8 ilkIndex) {
        POOL = pool;
        JOIN = gemJoin;

        if (gemJoin.POOL() != address(pool)) {
            revert InvalidContractConfigs(pool, gemJoin);
        }
        if (!pool.hasRole(pool.GEM_JOIN_ROLE(), address(gemJoin))) {
            revert InvalidContractConfigs(pool, gemJoin);
        }

        ILK_INDEX = ilkIndex;

        BASE = IERC20(pool.underlying());
        COLLATERAL = IERC20(gemJoin.GEM());
    }

    function _validateOrderParams(OrderParameters calldata params) internal {
        if (params.offer.length != 1) revert OffersLengthMustBeOne(params.offer.length);
        if (params.consideration.length != 2) revert ConsiderationsLengthMustBeTwo(params.consideration.length);
        if (params.zone != address(this)) revert ZoneMustBeThis(params.zone);
        if (params.orderType != OrderType.FULL_RESTRICTED) revert OrderTypeMustBeFullRestricted(params.orderType);
        if (params.conduitKey != bytes32(0)) revert ConduitKeyMustBeZero(params.conduitKey);
        if (params.totalOriginalConsiderationItems != 2) revert InvalidTotalOriginalConsiderationItems();
    }
}

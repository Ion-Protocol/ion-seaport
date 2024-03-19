// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SeaportTestBase} from "./SeaportTestBase.sol";
import {IIonPool} from "./../src/interfaces/IIonPool.sol";
import {SeaportLeverage} from "./../src/SeaportLeverage.sol";
import {
    OfferItem,
    ConsiderationItem,
    Order,
    OrderParameters,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { OrderType, ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";

contract SeaportLeverage_Test is SeaportTestBase {
    function _createOrder(
        IIonPool pool,
        SeaportLeverage deleverage,
        uint256 collateralToRemove,
        uint256 debtToRepay,
        uint256 salt
    ) internal returns (Order memory order) {
        OfferItem memory offerItem = OfferItem({
            itemType: ItemType.ERC20,
            token: address(pool.underlying()),
            identifierOrCriteria: 0,
            startAmount: debtToRepay,
            endAmount: debtToRepay
        });

        ConsiderationItem memory considerationItem = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(deleverage),
            identifierOrCriteria: 0,
            startAmount: 1e18,
            endAmount: 1e18,
            recipient: payable(address(this))
        });

        ConsiderationItem memory considerationItem2 = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: pool.getIlkAddress(0),
            identifierOrCriteria: 0,
            startAmount: collateralToRemove,
            endAmount: collateralToRemove,
            recipient: payable(offerer)
        });

        OfferItem[] memory offerItems = new OfferItem[](1);
        offerItems[0] = offerItem;

        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](
            2
        );
        considerationItems[0] = considerationItem;
        considerationItems[1] = considerationItem2;

        OrderParameters memory params = OrderParameters({
            offerer: offerer,
            zone: address(weEthSeaportDeleverage),
            offer: offerItems,
            consideration: considerationItems,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: 0,
            endTime: type(uint256).max,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: considerationItems.length
        });

        OrderComponents memory components = abi.decode(
            abi.encode(params),
            (OrderComponents)
        );
        bytes32 orderHash = seaport.getRealOrderHash(components);

        bytes32 digest = keccak256(
            abi.encodePacked(EIP_712_PREFIX, DOMAIN_SEPARATOR, orderHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(offererPrivateKey, digest);

        bytes memory signature = abi.encodePacked(r, s, v);

        order = Order({parameters: params, signature: signature});
    }

    function setUp() public override {
        
    }
}

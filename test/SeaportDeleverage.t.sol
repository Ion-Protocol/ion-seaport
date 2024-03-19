// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IIonPool } from "../src/interfaces/IIonPool.sol";
import { IGemJoin } from "../src/interfaces/IGemJoin.sol";
import { IUFDMHandler } from "../src/interfaces/IUFDMHandler.sol";
import { IWhitelist } from "../src/interfaces/IWhitelist.sol";
import { SeaportDeleverage } from "../src/SeaportDeleverage.sol";
import { SeaportTestBase } from "./SeaportTestBase.sol";

import { LidoLibrary } from "@ionprotocol/libraries/lst/LidoLibrary.sol";
import { KelpDaoLibrary } from "@ionprotocol/libraries/lrt/KelpDaoLibrary.sol";
import { IWstEth, IWeEth, IEEth, IRsEth } from "@ionprotocol/interfaces/ProviderInterfaces.sol";
import { EtherFiLibrary } from "@ionprotocol/libraries/lrt/EtherFiLibrary.sol";

import { Seaport } from "seaport-core/src/Seaport.sol";

import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";
import { OrderType, ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    OfferItem,
    ConsiderationItem,
    Order,
    OrderParameters,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { CalldataStart, CalldataPointer } from "seaport-types/src/helpers/PointerLibraries.sol";

import { Test } from "forge-std/Test.sol";

import { safeconsole as console } from "forge-std/safeconsole.sol";
import { console2 } from "forge-std/console2.sol";

using LidoLibrary for IWstEth;
using EtherFiLibrary for IWeEth;

contract SeaportDeleverage_Test is SeaportTestBase {
    uint256 collateralToRemove = 0.8e18;
    uint256 debtToRepay = 1 ether;

    function setUp() public override {
        super.setUp();

        uint256 initialDeposit = 10 ether; // in collateral terms
        uint256 resultingAdditionalCollateral = 20 ether; // in collateral terms
        uint256 maxResultingDebt = 25 ether;

        weEthIonPool.addOperator(address(weEthHandler));
        weEthIonPool.addOperator(address(weEthSeaportDeleverage));

        WSTETH.approve(address(weEthHandler), type(uint256).max);
        WSTETH.depositForLst(500 ether);
        // weEthHandler.deleverage(500 ether);
        weEthIonPool.addOperator(address(weEthHandler));

        WEETH.approve(address(weEthHandler), type(uint256).max);
        EETH.approve(address(WEETH), type(uint256).max);
        WEETH.depositForLrt(initialDeposit * 2);

        weEthHandler.flashswapAndMint(
            initialDeposit,
            resultingAdditionalCollateral,
            maxResultingDebt,
            block.timestamp + 1_000_000_000_000,
            new bytes32[](0)
        );
    }

    function test_WeEthDeleverage() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        (uint256 collateralBefore, uint256 debtBefore) = weEthIonPool.vault(0, address(this));
        uint256 debtBeforeRad = debtBefore * weEthIonPool.rate(0);

        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
        console.log("");

        (uint256 collateralAfter, uint256 debtAfter) = weEthIonPool.vault(0, address(this));
        uint256 debtAfterRad = debtAfter * weEthIonPool.rate(0);

        assertEq(collateralBefore - collateralAfter, collateralToRemove);
        // assertEq(debtBeforeRad - debtAfterRad, debtToRepay * 1e27);

        Order memory order2 =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 7);

        weEthSeaportDeleverage.deleverage(order2, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_OffersArrayLengthNotOne() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidLength = 2;
        OfferItem[] memory offerItems = new OfferItem[](invalidLength);
        order.parameters.offer = offerItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.OffersLengthMustBeOne.selector, invalidLength));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ConsiderationsArrayLengthNotTwo() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidLength = 3;
        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](invalidLength);
        order.parameters.consideration = considerationItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.ConsiderationsLengthMustBeTwo.selector, invalidLength));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ZoneIsNotDeleverageContract() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        address invalidZone = address(this);
        order.parameters.zone = invalidZone;

        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.ZoneMustBeThis.selector, invalidZone));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_OrderTypeNotFullRestricted() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        OrderType invalidOrderType = OrderType.FULL_OPEN;
        order.parameters.orderType = invalidOrderType;

        vm.expectRevert(
            abi.encodeWithSelector(SeaportDeleverage.OrderTypeMustBeFullRestricted.selector, invalidOrderType)
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ConduitKeyNotZero() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        bytes32 invalidConduitKey = bytes32(uint256(1));
        order.parameters.conduitKey = invalidConduitKey;

        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.ConduitKeyMustBeZero.selector, invalidConduitKey));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_TotalOriginalConsiderationItemsNotTwo() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidTotalOriginalConsiderationItems = 3;
        order.parameters.totalOriginalConsiderationItems = invalidTotalOriginalConsiderationItems;

        vm.expectRevert(SeaportDeleverage.InvalidTotalOriginalConsiderationItems.selector);
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }
}

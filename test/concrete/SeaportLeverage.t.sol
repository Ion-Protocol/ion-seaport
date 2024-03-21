// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SeaportBase } from "./../../src/SeaportBase.sol";
import { SeaportTestBase } from "../SeaportTestBase.sol";
import { IIonPool } from "./../../src/interfaces/IIonPool.sol";
import { SeaportLeverage } from "./../../src/SeaportLeverage.sol";
import {
    OfferItem,
    ConsiderationItem,
    Order,
    OrderParameters,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { OrderType, ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";

contract SeaportLeverage_Test is SeaportTestBase {
    uint256 initialDeposit = 10e18;
    uint256 resultingAdditionalCollateral = 12e18;
    uint256 collateralToPurchase = resultingAdditionalCollateral - initialDeposit;
    uint256 amountToBorrow = 2e18;

    function setUp() public override {
        super.setUp();

        // PERMISSIONS
        weEthIonPool.addOperator(address(weEthSeaportLeverage));
        // approve the ion-seaport handler to take user's collateral as initial deposit
        COLLATERAL.approve(address(weEthSeaportLeverage), type(uint256).max);
        // approve seaport to take offerer's collateral for swap
        vm.startPrank(offerer);
        COLLATERAL.approve(address(seaport), type(uint256).max);
        vm.stopPrank();

        setERC20Balance(address(COLLATERAL), offerer, collateralToPurchase);
        setERC20Balance(address(COLLATERAL), address(this), initialDeposit);
    }

    function test_WeEthLeverageFromEmptyVault() public {
        initialDeposit = 10e18;
        resultingAdditionalCollateral = 15e18; // 1.5x leverage

        collateralToPurchase = resultingAdditionalCollateral - initialDeposit;

        // fund offerer and user wallet with collateral asset
        setERC20Balance(address(COLLATERAL), offerer, collateralToPurchase);
        setERC20Balance(address(COLLATERAL), address(this), initialDeposit);

        // counterparty agreed to swap 18 base asset for 18 collateral asset 1:1
        amountToBorrow = collateralToPurchase;
        uint256 amountToBorrowRad = amountToBorrow * 1e27;

        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        (uint256 collateralBefore, uint256 debtBefore) = weEthIonPool.vault(0, address(this));
        uint256 debtBeforeRad = debtBefore * weEthIonPool.rate(0);
        uint256 debtBeforeWad = debtBeforeRad / 1e27;

        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );

        (uint256 collateralAfter, uint256 debtAfter) = weEthIonPool.vault(0, address(this));
        uint256 debtAfterRad = debtAfter * weEthIonPool.rate(0);
        uint256 debtAfterWad = debtAfterRad / 1e27;

        // normalizedAmount = floor(borrowAmount / rate) + 1 = ceil(borrowAmount / rate)
        // rounding error = normalizedAmount * rate - borrowAmount < rate
        uint256 maxResultingDebtRoundingError = weEthIonPool.rate(0);

        assertEq(BASE.balanceOf(address(weEthSeaportLeverage)), 0, "no asset dust should be left");
        assertEq(resultingAdditionalCollateral, collateralAfter, "resulting collateral amount");

        assertLe(
            debtAfterRad - amountToBorrowRad,
            maxResultingDebtRoundingError,
            "resulting debt in rad within max rounding error bound"
        );

        assertEq(collateralAfter - collateralBefore, resultingAdditionalCollateral, "change in collateral");
        assertEq(debtAfterWad - debtBeforeWad, amountToBorrow, "change in debt");
    }

    function test_WeEthLeverageFromExistingVault() public { }

    function test_RevertWhen_OffersArrayLengthNotOne() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        uint256 invalidLength = 2;
        OfferItem[] memory offerItems = new OfferItem[](invalidLength);
        order.parameters.offer = offerItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OffersLengthMustBeOne.selector, invalidLength));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_ConsiderationsArrayLengthNotTwo() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        uint256 invalidLength = 3;
        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](invalidLength);
        order.parameters.consideration = considerationItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ConsiderationsLengthMustBeTwo.selector, invalidLength));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_ZoneIsNotDeleverageContract() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        address invalidZone = address(this);
        order.parameters.zone = invalidZone;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ZoneMustBeThis.selector, invalidZone));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_OrderTypeNotFullRestricted() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        OrderType invalidOrderType = OrderType.FULL_OPEN;
        order.parameters.orderType = invalidOrderType;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OrderTypeMustBeFullRestricted.selector, invalidOrderType));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_ConduitKeyNotZero() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        bytes32 invalidConduitKey = bytes32(uint256(1));
        order.parameters.conduitKey = invalidConduitKey;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ConduitKeyMustBeZero.selector, invalidConduitKey));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_TotalOriginalConsiderationItemsNotTwo() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        uint256 invalidTotalOriginalConsiderationItems = 3;
        order.parameters.totalOriginalConsiderationItems = invalidTotalOriginalConsiderationItems;

        vm.expectRevert(SeaportBase.InvalidTotalOriginalConsiderationItems.selector);
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Offer1ItemTypeNotERC20() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.offer[0].itemType = ItemType.ERC1155;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OItemTypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Offer1TokenNotBase() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.offer[0].token = address(1);

        vm.expectRevert(abi.encodeWithSelector(SeaportLeverage.OTokenMustBeCollateral.selector, address(1)));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Offer1StartAmountNotCollateralToPurchase() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.offer[0].startAmount = amountToBorrow + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.OStartMustBeCollateralToPurchase.selector, amountToBorrow + 1, amountToBorrow
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Offer1EndAmountNotamountToBorrow() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.offer[0].endAmount = amountToBorrow + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.OEndMustBeCollateralToPurchase.selector, amountToBorrow + 1, amountToBorrow
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration1ItemTypeNotERC20() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[0].itemType = ItemType.ERC1155;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1TypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration1TokenNotDeleverageContract() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[0].token = address(1);

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1TokenMustBeThis.selector, address(1)));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration1StartAmountNotamountToBorrow() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[0].startAmount = amountToBorrow + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.C1StartAmountMustBeAmountToBorrow.selector, amountToBorrow + 1, amountToBorrow
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration1EndAmountNotAmountToBorrow() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[0].endAmount = amountToBorrow + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.C1EndAmountMustBeAmountToBorrow.selector, amountToBorrow + 1, amountToBorrow
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration1RecipientNotThis() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[0].recipient = payable(address(1));
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1RecipientMustBeSender.selector, address(1)));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration2ItemTypeNotERC20() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[1].itemType = ItemType.ERC1155;
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C2TypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration2TokenNotCollateral() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[1].token = address(1);
        vm.expectRevert(abi.encodeWithSelector(SeaportLeverage.C2TokenMustBeBase.selector, address(1)));
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration2StartNotcollateralToPurchase() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[1].startAmount = collateralToPurchase + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.C2StartMustBeAmountToBorrow.selector, collateralToPurchase + 1, collateralToPurchase
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_Consideration2EndNotcollateralToPurchase() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.consideration[1].endAmount = collateralToPurchase + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportLeverage.C2EndMustBeAmountToBorrow.selector, collateralToPurchase + 1, collateralToPurchase
            )
        );
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }

    function test_RevertWhen_SeaportNotCallerOnCallback() public {
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.MsgSenderMustBeSeaport.selector, address(this)));
        weEthSeaportLeverage.seaportCallback4878572495(address(0), address(0), 0);
    }

    function test_RevertWhen_LeverageNotInitiatedByContract() public {
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.orderType = OrderType.FULL_OPEN;

        OrderComponents memory components = abi.decode(abi.encode(order.parameters), (OrderComponents));
        bytes32 orderHash = seaport.getRealOrderHash(components);

        bytes32 digest = keccak256(abi.encodePacked(EIP_712_PREFIX, DOMAIN_SEPARATOR, orderHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(offererPrivateKey, digest);

        bytes memory signature = abi.encodePacked(r, s, v);

        order = Order({ parameters: order.parameters, signature: signature });

        vm.prank(offerer);
        vm.expectRevert(SeaportBase.NotAwaitingCallback.selector);
        seaport.fulfillOrder(order, bytes32(0));
    }

    function test_RevertWhen_LeverageAmountIsZero() public {
        uint256 initialDeposit = 1 ether; 
        uint256 resultingAdditionalCollateral = 1 ether; 
        uint256 collateralToPurchase = resultingAdditionalCollateral - initialDeposit;  
        
        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, collateralToPurchase, amountToBorrow, 1_241_289);

        order.parameters.orderType = OrderType.FULL_RESTRICTED;

        OrderComponents memory components = abi.decode(abi.encode(order.parameters), (OrderComponents));
        bytes32 orderHash = seaport.getRealOrderHash(components);

        bytes32 digest = keccak256(abi.encodePacked(EIP_712_PREFIX, DOMAIN_SEPARATOR, orderHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(offererPrivateKey, digest);

        bytes memory signature = abi.encodePacked(r, s, v);

        order = Order({ parameters: order.parameters, signature: signature });

        vm.expectRevert(SeaportLeverage.ZeroLeverageAmount.selector);
        weEthSeaportLeverage.leverage(
            order, initialDeposit, resultingAdditionalCollateral, amountToBorrow, new bytes32[](0)
        );
    }
}

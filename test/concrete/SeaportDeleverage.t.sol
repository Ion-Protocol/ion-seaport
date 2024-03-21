// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SeaportBase } from "./../../src/SeaportBase.sol";
import { SeaportDeleverage } from "../../src/SeaportDeleverage.sol";
import { SeaportTestBase } from "../SeaportTestBase.sol";

import { LidoLibrary } from "@ionprotocol/libraries/lst/LidoLibrary.sol";
import { IWstEth, IWeEth } from "@ionprotocol/interfaces/ProviderInterfaces.sol";
import { EtherFiLibrary } from "@ionprotocol/libraries/lrt/EtherFiLibrary.sol";

import { OrderType, ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import { OfferItem, ConsiderationItem, Order, OrderComponents } from "seaport-types/src/lib/ConsiderationStructs.sol";

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
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        (uint256 collateralBefore1, uint256 debtBefore1) = weEthIonPool.vault(0, address(this));
        uint256 debtBeforeRad = debtBefore1 * weEthIonPool.rate(0);

        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);

        (uint256 collateralAfter1, uint256 debtAfter1) = weEthIonPool.vault(0, address(this));
        uint256 debtAfterRad = debtAfter1 * weEthIonPool.rate(0);

        uint256 normalizedDebtToRepay = debtToRepay * 1e27 / weEthIonPool.rate(0);

        assertEq(collateralBefore1 - collateralAfter1, collateralToRemove);
        assertEq(debtBeforeRad - debtAfterRad, normalizedDebtToRepay * weEthIonPool.rate(0));

        Order memory order2 = _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 7);

        weEthSeaportDeleverage.deleverage(order2, collateralToRemove, debtToRepay);

        (uint256 collateralAfter2, uint256 debtAfter2) = weEthIonPool.vault(0, address(this));

        assertEq(collateralAfter1 - collateralAfter2, collateralToRemove);
        assertEq(debtAfterRad - debtAfter2 * weEthIonPool.rate(0), normalizedDebtToRepay * weEthIonPool.rate(0));
    }

    function test_WeEthFullDeleverage() public {
        uint256 currentDebt = weEthIonPool.normalizedDebt(0, address(this)) * weEthIonPool.rate(0) / 1e27;
        uint256 currentDebtPlusBound = currentDebt * 1.08e18 / 1e18;
        debtToRepay = currentDebtPlusBound;

        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        (uint256 collateralBefore,) = weEthIonPool.vault(0, address(this));
        uint256 baseThisBalanceBefore = WSTETH.balanceOf(address(this));
        uint256 basePoolBalanaceBefore = WSTETH.balanceOf(address(weEthIonPool));

        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);

        (uint256 collateralAfter, uint256 debtAfter) = weEthIonPool.vault(0, address(this));

        assertEq(collateralBefore - collateralAfter, collateralToRemove);
        assertEq(debtAfter, 0);
        assertEq(WSTETH.balanceOf(address(weEthSeaportDeleverage)), 0);

        // Check that currentDebtPlusBound (which is the amount of BASE provided
        // by market maker) is equal to the BASE used by POOL and refunded to
        // user.
        uint256 baseThisBalanceDiff = WSTETH.balanceOf(address(this)) - baseThisBalanceBefore;
        uint256 basePoolBalanaceDiff = WSTETH.balanceOf(address(weEthIonPool)) - basePoolBalanaceBefore;
        assertEq(baseThisBalanceDiff + basePoolBalanaceDiff, currentDebtPlusBound);
    }

    function test_RevertWhen_CollateralToRemoveGreaterThanVaultCollateral() public {
        uint256 collateral = weEthIonPool.collateral(0, address(this));
        collateralToRemove = collateral + 1;

        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        vm.expectRevert(
            abi.encodeWithSelector(SeaportDeleverage.NotEnoughCollateral.selector, collateral + 1, collateral)
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_OffersArrayLengthNotOne() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidLength = 2;
        OfferItem[] memory offerItems = new OfferItem[](invalidLength);
        order.parameters.offer = offerItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OffersLengthMustBeOne.selector, invalidLength));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ConsiderationsArrayLengthNotTwo() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidLength = 3;
        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](invalidLength);
        order.parameters.consideration = considerationItems;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ConsiderationsLengthMustBeTwo.selector, invalidLength));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ZoneIsNotDeleverageContract() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        address invalidZone = address(this);
        order.parameters.zone = invalidZone;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ZoneMustBeThis.selector, invalidZone));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_OrderTypeNotFullRestricted() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        OrderType invalidOrderType = OrderType.FULL_OPEN;
        order.parameters.orderType = invalidOrderType;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OrderTypeMustBeFullRestricted.selector, invalidOrderType));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_ConduitKeyNotZero() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        bytes32 invalidConduitKey = bytes32(uint256(1));
        order.parameters.conduitKey = invalidConduitKey;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.ConduitKeyMustBeZero.selector, invalidConduitKey));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_TotalOriginalConsiderationItemsNotTwo() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        uint256 invalidTotalOriginalConsiderationItems = 3;
        order.parameters.totalOriginalConsiderationItems = invalidTotalOriginalConsiderationItems;

        vm.expectRevert(SeaportBase.InvalidTotalOriginalConsiderationItems.selector);
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Offer1ItemTypeNotERC20() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.offer[0].itemType = ItemType.ERC1155;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.OItemTypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Offer1TokenNotBase() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.offer[0].token = address(1);

        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.OTokenMustBeBase.selector, address(1)));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Offer1StartAmountNotDebtToRepay() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.offer[0].startAmount = debtToRepay + 1;

        vm.expectRevert(
            abi.encodeWithSelector(SeaportDeleverage.OStartMustBeDebtToRepay.selector, debtToRepay + 1, debtToRepay)
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Offer1EndAmountNotDebtToRepay() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.offer[0].endAmount = debtToRepay + 1;

        vm.expectRevert(
            abi.encodeWithSelector(SeaportDeleverage.OEndMustBeDebtToRepay.selector, debtToRepay + 1, debtToRepay)
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration1ItemTypeNotERC20() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[0].itemType = ItemType.ERC1155;

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1TypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration1TokenNotDeleverageContract() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[0].token = address(1);

        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1TokenMustBeThis.selector, address(1)));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration1StartAmountNotDebtToRepay() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[0].startAmount = debtToRepay + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportDeleverage.C1StartAmountMustBeDebtToRepay.selector, debtToRepay + 1, debtToRepay
            )
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration1EndAmountNotDebtToRepay() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[0].endAmount = debtToRepay + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportDeleverage.C1EndAmountMustBeDebtToRepay.selector, debtToRepay + 1, debtToRepay
            )
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration1RecipientNotThis() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[0].recipient = payable(address(1));
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C1RecipientMustBeSender.selector, address(1)));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration2ItemTypeNotERC20() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[1].itemType = ItemType.ERC1155;
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.C2TypeMustBeERC20.selector, ItemType.ERC1155));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration2TokenNotCollateral() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[1].token = address(1);
        vm.expectRevert(abi.encodeWithSelector(SeaportDeleverage.C2TokenMustBeCollateral.selector, address(1)));
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration2StartNotCollateralToRemove() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[1].startAmount = collateralToRemove + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportDeleverage.C2StartMustBeCollateralToRemove.selector, collateralToRemove + 1, collateralToRemove
            )
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_Consideration2EndNotCollateralToRemove() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

        order.parameters.consideration[1].endAmount = collateralToRemove + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SeaportDeleverage.C2EndMustBeCollateralToRemove.selector, collateralToRemove + 1, collateralToRemove
            )
        );
        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);
    }

    function test_RevertWhen_SeaportNotCallerOnCallback() public {
        vm.expectRevert(abi.encodeWithSelector(SeaportBase.MsgSenderMustBeSeaport.selector, address(this)));
        weEthSeaportDeleverage.seaportCallback4878572495(address(0), address(0), 0);
    }

    function test_RevertWhen_DeleverageNotInitiatedByContract() public {
        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, debtToRepay, 1_241_289);

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
}

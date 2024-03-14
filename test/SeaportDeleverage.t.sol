// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IIonPool } from "../src/interfaces/IIonPool.sol";
import { IGemJoin } from "../src/interfaces/IGemJoin.sol";
import { IUFDMHandler } from "../src/interfaces/IUFDMHandler.sol";
import { IWhitelist } from "../src/interfaces/IWhitelist.sol";
import { SeaportDeleverage } from "../src/SeaportDeleverage.sol";

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

using EtherFiLibrary for IWeEth;
using KelpDaoLibrary for IRsEth;
using LidoLibrary for IWstEth;

IWstEth constant WSTETH = IWstEth(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
IWeEth constant WEETH = IWeEth(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
IEEth constant EETH = IEEth(0x35fA164735182de50811E8e2E824cFb9B6118ac2);

bytes2 constant EIP_712_PREFIX = 0x1901;
bytes32 constant DOMAIN_SEPARATOR = 0x0f85f982cb046fcb7b2fc93614d188c004d0bf3bbba78bfb40bc7ee8e099fa47;

contract SeaportOrderHash is Seaport {
    constructor(address conduitController) Seaport(conduitController) { }

    function getRealOrderHash(
        /**
         * @custom:name order
         */
        OrderComponents calldata order
    )
        external
        view
        returns (bytes32 orderHash)
    {
        CalldataPointer orderPointer = CalldataStart.pptr();

        // Derive order hash by supplying order parameters along with counter.
        orderHash = _deriveOrderHash(
            abi.decode(abi.encode(order), (OrderParameters)),
            // Read order counter
            _getCounter(_toOrderParametersReturnType(_decodeOrderComponentsAsOrderParameters)(orderPointer).offerer)
        );

        console.log("test");
        console2.logBytes32(orderHash);
    }
}

contract SeaportTest is Test {
    IIonPool weEthIonPool;
    IGemJoin weEthGemJoin;
    IUFDMHandler weEthHandler;

    IIonPool rsEthIonPool;
    IGemJoin rsEthGemJoin;
    IUFDMHandler rsEthHandler;

    IWhitelist whitelist;

    uint256 offererPrivateKey;
    address offerer;
    address fulfiller;

    SeaportOrderHash seaport;
    SeaportDeleverage weEthSeaportDeleverage;
    SeaportDeleverage rsEthSeaportDeleverage;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        weEthIonPool = IIonPool(0x0000000000eaEbd95dAfcA37A39fd09745739b78);
        weEthGemJoin = IGemJoin(0x3f6119B0328C27190bE39597213ea1729f061876);
        weEthHandler = IUFDMHandler(payable(0xAB3c6236327FF77159B37f18EF85e8AC58034479));

        rsEthIonPool = IIonPool(0x0000000000E33e35EE6052fae87bfcFac61b1da9);
        rsEthGemJoin = IGemJoin(0x3bC3AC09d1ee05393F2848d82cb420f347954432);
        rsEthHandler = IUFDMHandler(payable(0x335FBFf118829Aa5ef0ac91196C164538A21a45A));

        weEthSeaportDeleverage = new SeaportDeleverage(weEthIonPool, weEthGemJoin);
        rsEthSeaportDeleverage = new SeaportDeleverage(rsEthIonPool, rsEthGemJoin);

        seaport = SeaportOrderHash(payable(address(weEthSeaportDeleverage.SEAPORT())));

        SeaportOrderHash s = new SeaportOrderHash(0x00000000F9490004C11Cef243f5400493c00Ad63);
        vm.etch(address(seaport), address(s).code);

        whitelist = IWhitelist(0x7E317f99aA313669AaCDd8dB3927ff3aCB562dAD);

        (offerer, offererPrivateKey) = makeAddrAndKey("offerer");
        fulfiller = makeAddr("fulfiller");

        vm.startPrank(whitelist.owner());
        whitelist.updateBorrowersRoot(0, bytes32(0));
        whitelist.updateLendersRoot(bytes32(0));
        vm.stopPrank();

        vm.deal(offerer, 10 ether);
        vm.startPrank(offerer);
        WSTETH.depositForLst(10 ether);
        WSTETH.approve(address(seaport), type(uint256).max);
        vm.stopPrank();

        _setupPool(weEthIonPool);
        _setupPool(rsEthIonPool);
    }

    function test_WeEthDeleverage() public {
        uint256 initialDeposit = 4 ether; // in collateral terms
        uint256 resultingAdditionalCollateral = 10 ether; // in collateral terms
        uint256 maxResultingDebt = 15 ether;

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

        uint256 collateralToRemove = 0.8e18;
        uint256 debtToRepay = 1 ether;

        Order memory order = _createOrder(weEthIonPool, weEthHandler, weEthSeaportDeleverage, collateralToRemove, debtToRepay);

        (uint256 collateralBefore, uint256 debtBefore) = weEthIonPool.vault(0, address(this)); 
        uint256 debtBeforeRad = debtBefore * weEthIonPool.rate(0);

        weEthSeaportDeleverage.deleverage(order, collateralToRemove, debtToRepay);

        (uint256 collateralAfter, uint256 debtAfter) = weEthIonPool.vault(0, address(this)); 
        uint256 debtAfterRad = debtAfter * weEthIonPool.rate(0);

        assertEq(collateralBefore - collateralAfter, collateralToRemove);
        // assertEq(debtBeforeRad - debtAfterRad, debtToRepay * 1e27);
    }

    function _setupPool(IIonPool pool) internal {
        vm.prank(pool.owner());
        pool.updateSupplyCap(1_000_000 ether);
        vm.prank(pool.owner());
        pool.updateIlkDebtCeiling(0, 1_000_000e45);
        WSTETH.depositForLst(500 ether);
        WSTETH.approve(address(pool), type(uint256).max);
        pool.supply(address(this), WSTETH.balanceOf(address(this)), new bytes32[](0));
    }

    function _createOrder(
        IIonPool pool,
        IUFDMHandler handler,
        SeaportDeleverage deleverage,
        uint256 collateralToRemove,
        uint256 debtToRepay
    )
        internal
        returns (Order memory order)
    {
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

        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](2);
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
            salt: 0,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: seaport.getCounter(offerer)
        });

        OrderComponents memory components = abi.decode(abi.encode(params), (OrderComponents));
        bytes32 orderHash = seaport.getRealOrderHash(components);

        bytes32 digest = keccak256(abi.encodePacked(EIP_712_PREFIX, DOMAIN_SEPARATOR, orderHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(offererPrivateKey, digest);

        bytes memory signature = abi.encodePacked(r, s, v);

        order = Order({ parameters: params, signature: signature });
    }
}

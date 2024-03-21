// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SeaportTestBase } from "../SeaportTestBase.sol";
import { WadRayMath } from "@ionprotocol/libraries/math/WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { LidoLibrary } from "@ionprotocol/libraries/lst/LidoLibrary.sol";
import { IWstEth, IWeEth } from "@ionprotocol/interfaces/ProviderInterfaces.sol";
import { EtherFiLibrary } from "@ionprotocol/libraries/lrt/EtherFiLibrary.sol";

import { Order } from "seaport-types/src/lib/ConsiderationStructs.sol";

using LidoLibrary for IWstEth;
using EtherFiLibrary for IWeEth;
using WadRayMath for uint256;
using Math for uint256;

contract SeaportDeleverage_FuzzTest is SeaportTestBase {
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

    struct Locs {
        uint256 normalizedDebtToRepay;
        uint256 debtToRepay;
        uint256 rate;
        uint256 currentNormalizedDebt;
        uint256 currentCollateral;
        uint256 leftOverNormalizedDebt;
        uint256 spotPrice;
        uint256 minimumLeftOverCollateral;
        uint256 maxCollateralToRemove;
    }

    function testFuzz_WeEthDeleverage(uint256 collateralToRemove, uint256 normalizedDebtToRepay) public {
        bool fullDeleverage;

        Locs memory locs;

        locs.rate = weEthIonPool.rate(0);

        locs.currentNormalizedDebt = weEthIonPool.normalizedDebt(0, address(this));
        locs.normalizedDebtToRepay = bound(normalizedDebtToRepay, 1, locs.currentNormalizedDebt);
        locs.leftOverNormalizedDebt = locs.currentNormalizedDebt - locs.normalizedDebtToRepay;
        if (locs.leftOverNormalizedDebt * locs.rate < weEthIonPool.dust(0)) {
            locs.debtToRepay = locs.currentNormalizedDebt.rayMulUp(locs.rate);
            fullDeleverage = true;
        } else {
            locs.debtToRepay = locs.normalizedDebtToRepay.rayMulUp(locs.rate);
        }

        locs.currentCollateral = weEthIonPool.collateral(0, address(this));
        locs.spotPrice = weEthIonPool.spot(0).getSpot();
        locs.minimumLeftOverCollateral =
            locs.leftOverNormalizedDebt.mulDiv(locs.rate, locs.spotPrice, Math.Rounding.Ceil);
        locs.maxCollateralToRemove = locs.currentCollateral - locs.minimumLeftOverCollateral;
        collateralToRemove = bound(collateralToRemove, 1, locs.maxCollateralToRemove);

        Order memory order =
            _createOrder(weEthIonPool, weEthSeaportDeleverage, collateralToRemove, locs.debtToRepay, 1_241_289);

        (uint256 collateralBefore1, uint256 debtBefore1) = weEthIonPool.vault(0, address(this));
        uint256 debtBeforeRad = debtBefore1 * weEthIonPool.rate(0);

        weEthSeaportDeleverage.deleverage(order, collateralToRemove, locs.debtToRepay);

        (uint256 collateralAfter1, uint256 debtAfter1) = weEthIonPool.vault(0, address(this));
        uint256 debtAfterRad = debtAfter1 * weEthIonPool.rate(0);

        assertEq(collateralBefore1 - collateralAfter1, collateralToRemove);
        if (fullDeleverage) {
            assertEq(debtAfterRad, 0);
        } else {
            assertEq(debtBeforeRad - debtAfterRad, locs.normalizedDebtToRepay * weEthIonPool.rate(0));
        }
    }
}

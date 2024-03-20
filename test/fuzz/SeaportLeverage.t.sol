// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SeaportTestBase } from "../SeaportTestBase.sol";
import { WadRayMath, WAD, RAY, RAD } from "ion-protocol/src/libraries/math/WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Order } from "seaport-types/src/lib/ConsiderationStructs.sol";
import { console2 } from "forge-std/console2.sol";

contract SeaportLeverage_FuzzTest is SeaportTestBase {
    using WadRayMath for uint256;
    using Math for uint256;

    uint256 constant SALT = 1_241_289;
    uint256 constant MIN_RESULTING_ADDITIONAL_DEPOSIT = 1 ether;
    uint256 constant MAX_RESULTING_ADDITIONAL_DEPOSIT = 100_000 ether;

    function setUp() public override {
        super.setUp();

        weEthIonPool.addOperator(address(weEthSeaportLeverage));
        // approve the ion-seaport handler to take user's collateral as initial deposit
        COLLATERAL.approve(address(weEthSeaportLeverage), type(uint256).max);
        // approve seaport to take offerer's collateral for swap
        vm.startPrank(offerer);
        COLLATERAL.approve(address(seaport), type(uint256).max);
        vm.stopPrank();

        // max supply in InPool
        vm.startPrank(weEthIonPool.owner());
        weEthIonPool.updateSupplyCap(type(uint256).max);
        weEthIonPool.updateIlkDebtCeiling(0, type(uint256).max);
        weEthIonPool.updateIlkDust(0, 0);
        vm.stopPrank();

        BASE.approve(address(weEthIonPool), type(uint256).max);
        vm.deal(address(this), type(uint256).max);
        setERC20Balance(address(BASE), address(this), type(uint256).max);

        weEthIonPool.supply(address(this), type(uint256).max / 2, new bytes32[](0));
    }

    struct Locs {
        uint256 spotPrice;
        uint256 rate;
        uint256 ltv;
        uint256 dust;
        uint256 liquidity;
        uint256 amountToBorrow;
        uint256 initialDeposit;
        uint256 collateralToPurchase;
        uint256 minimumResultingAdditionalDeposit;
    }

    /**
     * @dev Fuzz initial, additional collateral amounts
     * initial deposit
     * resulting additional deposit
     * exchange rate between collateral asset and base asset
     * protocol rate
     *
     * fuzz initial deposit, resulting additional deposit,
     *
     *
     */
    function testFuzz_WeEthLeverageEmptyVault(uint256 resultingAdditionalDeposit, uint256 amountToBorrow) public {
        Locs memory locs;
        locs.spotPrice = weEthIonPool.spot(0).getSpot();
        locs.rate = weEthIonPool.rate(0);
        locs.ltv = weEthIonPool.spot(0).LTV();
        locs.dust = weEthIonPool.dust(0);
        locs.liquidity = weEthIonPool.weth();

        console2.log("locs.spotPrice", locs.spotPrice);
        console2.log("locs.ltv", locs.ltv);

        vm.assume(resultingAdditionalDeposit > 1);

        resultingAdditionalDeposit =
            bound(resultingAdditionalDeposit, MIN_RESULTING_ADDITIONAL_DEPOSIT, MAX_RESULTING_ADDITIONAL_DEPOSIT);
        console2.log("bounded resultingAdditionalDeposit", resultingAdditionalDeposit);

        locs.initialDeposit = bound(locs.initialDeposit, 1, resultingAdditionalDeposit - 1);
        console2.log("bounded initialDeposit", locs.initialDeposit);
        locs.collateralToPurchase = resultingAdditionalDeposit - locs.initialDeposit;
        console2.log("collateralToPurchase", locs.collateralToPurchase);

        setERC20Balance(address(COLLATERAL), address(this), locs.initialDeposit);
        setERC20Balance(address(COLLATERAL), offerer, locs.collateralToPurchase);

        console2.log("after set erc20 balance");

        (uint256 collateralBefore, uint256 debtBefore) = weEthIonPool.vault(0, address(this));

        // spot * resultingAdditionalDeposit * liquidationThreshold > normalizedDebt * rate
        uint256 adjCollateralValueWad =
            resultingAdditionalDeposit.mulDiv(locs.spotPrice, RAY, Math.Rounding.Floor).mulDiv(locs.ltv, RAY);
        console2.log("adjCollateralValueWad", adjCollateralValueWad);

        // bound amountToborrow to avoid unsafe position change or liquidity underflow
        uint256 amountToBorrowMaxBound = locs.liquidity < adjCollateralValueWad ? locs.liquidity : adjCollateralValueWad;
        amountToBorrow = bound(amountToBorrow, locs.dust, amountToBorrowMaxBound);

        console2.log("bounded amountToBorrow", amountToBorrow);

        vm.assume(amountToBorrow != 0);

        Order memory order =
            _createLeverageOrder(weEthIonPool, weEthSeaportLeverage, locs.collateralToPurchase, amountToBorrow, SALT);

        weEthSeaportLeverage.leverage(
            order, locs.initialDeposit, resultingAdditionalDeposit, amountToBorrow, new bytes32[](0)
        );

        uint256 normalizedDebtAfter = weEthIonPool.normalizedDebt(0, address(this));
        uint256 debtAfterRad = normalizedDebtAfter * locs.rate;
        (uint256 collateralAfter, uint256 debtAfter) = weEthIonPool.vault(0, address(this));

        // no dust left in the contract in base asset or collateral asset
        assertLe(BASE.balanceOf(address(weEthSeaportLeverage)), 1, "base asset dust below 1 wei");
        assertEq(COLLATERAL.balanceOf(address(weEthSeaportLeverage)), 0, "no collateral asset dust");

        // exact desired amount of collateral reached
        assertEq(collateralAfter, resultingAdditionalDeposit, "resulting collateral amount");

        // resulting debt amount under maximum dust bounded by the rate
        assertLe(debtAfterRad - amountToBorrow * RAY, locs.rate, "resulting debt rounding error rate bound");
        // assertEq(debtAfter, amountToBorrow, "resulting debt amount in wad");

        // exact amounts of assets transferred
        assertEq(COLLATERAL.balanceOf(address(this)), 0, "all initial deposit transferred");
        assertEq(COLLATERAL.balanceOf(offerer), 0, "all collateral transferred from offerer");
    }

    function testFuzz_WeEthLeverageExistingVaultNoInitialDeposit() public { }

    function testFuzz_WeEthLeverageExistingVaultWithInitialDeposit() public { }
}

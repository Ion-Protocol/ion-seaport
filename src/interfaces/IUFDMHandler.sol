// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface IUFDMHandler {
    error AddressEmptyCode(address target);
    error AddressInsufficientBalance(address account);
    error CallbackOnlyCallableByPool(address unauthorizedCaller);
    error CannotSendEthToContract();
    error FailedInnerCall();
    error FlashloanRepaymentTooExpensive(uint256 repaymentAmount, uint256 maxRepaymentAmount);
    error InvalidUniswapPool();
    error InvalidZeroLiquidityRegionSwap();
    error MathOverflowedMulDiv();
    error OutputAmountNotReceived(uint256 amountReceived, uint256 amountRequired);
    error SafeCastOverflowedUintToInt(uint256 value);
    error SafeERC20FailedOperation(address token);
    error TransactionDeadlineReached(uint256 deadline);

    receive() external payable;

    function BASE() external view returns (address);
    function ILK_INDEX() external view returns (uint8);
    function JOIN() external view returns (address);
    function LST_TOKEN() external view returns (address);
    function MINT_ASSET() external view returns (address);
    function POOL() external view returns (address);
    function UNISWAP_POOL() external view returns (address);
    function WETH() external view returns (address);
    function WHITELIST() external view returns (address);
    function depositAndBorrow(uint256 amountCollateral, uint256 amountToBorrow, bytes32[] memory proof) external;
    function flashswapAndMint(
        uint256 initialDeposit,
        uint256 resultingAdditionalCollateral,
        uint256 maxResultingDebt,
        uint256 deadline,
        bytes32[] memory proof
    )
        external;
    function repayAndWithdraw(uint256 debtToRepay, uint256 collateralToWithdraw) external;
    function repayFullAndWithdraw(uint256 collateralToWithdraw) external;
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory _data) external;
}

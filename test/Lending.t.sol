// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {Lending} from "../src/Lending.sol";

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract LendingTest is Test {
    using stdStorage for StdStorage;

    Lending public lending;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public nonOwner = makeAddr("nonOwner");

    event TokenConfigured(
        address indexed token,
        uint256 collateralFactorBps,
        bool enabled,
        uint256 timestamp
    );

    event PriceConfigured(
        address indexed token,
        uint256 price,
        uint256 updatedAt
    );

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event Borrow(
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    function setUp() public {
        vm.prank(owner);
        lending = new Lending(owner);
        tokenA = new MockERC20();
        tokenB = new MockERC20();
    }

    /* -------------------------------------------------------------------------- */
    /*                               INITIAL STATE                                */
    /* -------------------------------------------------------------------------- */

    function test_OwnerIsSetCorrectly() public view {
        assertEq(lending.owner(), owner);
    }

    function test_InitialCollateralBalanceIsZero() public view {
        assertEq(lending.collateralBalance(user, address(tokenA)), 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                              CONFIGURE TOKEN                               */
    /* -------------------------------------------------------------------------- */

    function test_ConfigureToken_Success() public {
        uint256 factorBps = 7500; // 75%

        vm.prank(owner);
        lending.configureToken(address(tokenA), factorBps, true);

        (bool enabled, uint256 configuredFactorBps, address tokenAddr) = lending.config(address(tokenA));
        assertTrue(enabled);
        assertEq(configuredFactorBps, factorBps);
        assertEq(tokenAddr, address(tokenA));
    }

    function test_ConfigureToken_RevertWhen_InvalidCollateralFactor() public {
        vm.prank(owner);
        vm.expectRevert(Lending.InvalidCollateralFactor.selector);
        lending.configureToken(address(tokenA), 10_001, true);
    }

    function test_ConfigureToken_RevertWhen_NotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(Lending.NotOwner.selector);
        lending.configureToken(address(tokenA), 5000, true);
    }

    function test_ConfigureToken_RevertWhen_TokenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Lending.TokenNotFound.selector);
        lending.configureToken(address(0), 5000, true);
    }

    /* -------------------------------------------------------------------------- */
    /*                              CONFIGURE PRICE                               */
    /* -------------------------------------------------------------------------- */

    function test_ConfigureTokenPrice_Success() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18); // $2000
        vm.stopPrank();

        uint256 price = lending.getLatestPrice(address(tokenA));
        assertEq(price, 2000 * 1e18);
    }

    function test_ConfigureTokenPrice_RevertWhen_ZeroPrice() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        vm.expectRevert(Lending.InvalidPrice.selector);
        lending.configureTokenPrice(address(tokenA), 0);
        vm.stopPrank();
    }

    function test_GetLatestPrice_RevertWhen_PriceNotFound() public {
        vm.expectRevert(Lending.PriceNotFound.selector);
        lending.getLatestPrice(address(tokenA));
    }

    function test_GetLatestPrice_RevertWhen_StalePrice() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);
        vm.stopPrank();

        // Warp past 5 days
        vm.warp(block.timestamp + 5 days + 1);
        vm.expectRevert(Lending.StalePrice.selector);
        lending.getLatestPrice(address(tokenA));
    }

    /* -------------------------------------------------------------------------- */
    /*                            DEPOSIT COLLATERAL                              */
    /* -------------------------------------------------------------------------- */

    function test_DepositCollateral_Success() public {
        uint256 depositAmount = 10 * 1e18;

        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        vm.stopPrank();

        tokenA.mint(user, depositAmount);

        vm.startPrank(user);
        tokenA.approve(address(lending), depositAmount);
        lending.depositCollateral(depositAmount, address(tokenA));
        vm.stopPrank();

        assertEq(lending.collateralBalance(user, address(tokenA)), depositAmount);
        assertEq(tokenA.balanceOf(address(lending)), depositAmount);
    }

    function test_DepositCollateral_RevertWhen_TokenDisabled() public {
        vm.prank(owner);
        lending.configureToken(address(tokenA), 7500, false);

        vm.startPrank(user);
        vm.expectRevert(Lending.TokenDisabled.selector);
        lending.depositCollateral(10 * 1e18, address(tokenA));
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                         COLLATERAL VALUE & CAPACITY                        */
    /* -------------------------------------------------------------------------- */

    function test_CollateralValue_And_BorrowingCapacity() public {
        // Setup: TokenA price = $2,000, 75% CF (7500 bps)
        // User deposits 2 TokenA -> Collateral Value = $4,000
        // Max Borrow Capacity = $4,000 * 75% = $3,000
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);
        vm.stopPrank();

        tokenA.mint(user, 2 * 1e18);

        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));
        vm.stopPrank();

        uint256 tokenCollateralVal = lending.getCollateralValue(user, address(tokenA));
        assertEq(tokenCollateralVal, 4000 * 1e18);

        uint256 totalCollateralVal = lending.getTotalCollateralValue(user);
        assertEq(totalCollateralVal, 4000 * 1e18);

        uint256 borrowCapacity = lending.getBorrowingCapacity(user);
        assertEq(borrowCapacity, 3000 * 1e18);

        uint256 remainingCapacity = lending.getRemainingBorrowCapacity(user);
        assertEq(remainingCapacity, 3000 * 1e18);
    }

    function test_BorrowCapacityCheck_SuccessAndRevert() public {
        // Setup: TokenA (Collateral) price = $2,000, CF = 7500 bps (75%)
        // Deposit 2 TokenA ($4,000) => Capacity = $3,000
        // TokenB (Borrow token) price = $1 (stablecoin)
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);

        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        tokenA.mint(user, 2 * 1e18);
        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));
        vm.stopPrank();

        // Check borrow 3,000 TokenB ($3,000 value) -> Should pass
        assertTrue(lending.checkBorrowCapacity(user, address(tokenB), 3000 * 1e18));

        // Check borrow 3,001 TokenB ($3,001 value) -> Exceeds capacity of $3,000
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.ExceedsBorrowCapacity.selector,
                3001 * 1e18,
                3000 * 1e18
            )
        );
        lending.checkBorrowCapacity(user, address(tokenB), 3001 * 1e18);
    }

    function test_BorrowCapacityWithExistingDebt() public {
        // Setup: User has $3,000 capacity, but already owes 1,000 TokenB ($1,000 debt)
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);

        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        tokenA.mint(user, 2 * 1e18);
        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));
        vm.stopPrank();

        // Simulate debt: user owes 1,000 TokenB using stdstore
        stdstore
            .target(address(lending))
            .sig("debtOwed(address,address)")
            .with_key(user)
            .with_key(address(tokenB))
            .checked_write(1000 * 1e18);

        uint256 totalDebt = lending.getTotalDebtValue(user);
        assertEq(totalDebt, 1000 * 1e18);

        uint256 remainingCapacity = lending.getRemainingBorrowCapacity(user);
        assertEq(remainingCapacity, 2000 * 1e18);

        // Can borrow up to remaining capacity ($2,000)
        assertTrue(lending.checkBorrowCapacity(user, address(tokenB), 2000 * 1e18));

        // Borrowing 2,001 should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.ExceedsBorrowCapacity.selector,
                2001 * 1e18,
                2000 * 1e18
            )
        );
        lending.checkBorrowCapacity(user, address(tokenB), 2001 * 1e18);
    }

    /* -------------------------------------------------------------------------- */
    /*                                BORROW FLOW                                 */
    /* -------------------------------------------------------------------------- */

    function test_Borrow_Success() public {
        // Setup:
        // TokenA = $2,000 (collateral), CF = 7500 bps (75%)
        // TokenB = $1 (borrow asset)
        // User deposits 2 TokenA ($4,000 collateral) -> Capacity = $3,000
        // Contract has 10,000 TokenB in liquidity
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);

        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        tokenB.mint(address(lending), 10_000 * 1e18); // Liquidity in lending contract

        tokenA.mint(user, 2 * 1e18);
        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));

        // Expect Borrow event
        vm.expectEmit(true, true, false, true, address(lending));
        emit Borrow(user, address(tokenB), 1500 * 1e18);

        // Borrow 1,500 TokenB
        lending.borrow(address(tokenB), 1500 * 1e18);
        vm.stopPrank();

        // Check balances and state
        assertEq(lending.debtOwed(user, address(tokenB)), 1500 * 1e18);
        assertEq(tokenB.balanceOf(user), 1500 * 1e18);
        assertEq(tokenB.balanceOf(address(lending)), 8500 * 1e18);

        // Check remaining borrow capacity is now $1,500 ($3,000 max - $1,500 debt)
        assertEq(lending.getRemainingBorrowCapacity(user), 1500 * 1e18);
    }

    function test_Borrow_RevertWhen_AssetNotSupported() public {
        MockERC20 unsupportedToken = new MockERC20();

        vm.startPrank(user);
        vm.expectRevert(Lending.TokenNotFound.selector);
        lending.borrow(address(unsupportedToken), 100 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_RevertWhen_AssetDisabled() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenB), 8000, false);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(Lending.TokenDisabled.selector);
        lending.borrow(address(tokenB), 100 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_RevertWhen_OraclePriceMissing() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenB), 8000, true);
        // Price not configured
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(Lending.PriceNotFound.selector);
        lending.borrow(address(tokenB), 100 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_RevertWhen_OraclePriceStale() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        // Warp past 5 days
        vm.warp(block.timestamp + 5 days + 1);

        vm.startPrank(user);
        vm.expectRevert(Lending.StalePrice.selector);
        lending.borrow(address(tokenB), 100 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_RevertWhen_ExceedsCapacity() public {
        // Setup: Deposit 2 TokenA ($4,000) => Capacity = $3,000
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);

        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        tokenB.mint(address(lending), 10_000 * 1e18);
        tokenA.mint(user, 2 * 1e18);

        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));

        // Attempt to borrow 3,001 TokenB ($3,001) > $3,000
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.ExceedsBorrowCapacity.selector,
                3001 * 1e18,
                3000 * 1e18
            )
        );
        lending.borrow(address(tokenB), 3001 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_RevertWhen_ZeroAmount() public {
        vm.startPrank(user);
        vm.expectRevert(Lending.InvalidAmount.selector);
        lending.borrow(address(tokenB), 0);
        vm.stopPrank();
    }

    function test_Borrow_MultipleBorrows_AccumulateDebt() public {
        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 7500, true);
        lending.configureTokenPrice(address(tokenA), 2000 * 1e18);

        lending.configureToken(address(tokenB), 8000, true);
        lending.configureTokenPrice(address(tokenB), 1 * 1e18);
        vm.stopPrank();

        tokenB.mint(address(lending), 10_000 * 1e18);
        tokenA.mint(user, 2 * 1e18);

        vm.startPrank(user);
        tokenA.approve(address(lending), 2 * 1e18);
        lending.depositCollateral(2 * 1e18, address(tokenA));

        // First borrow: 1000 TokenB
        lending.borrow(address(tokenB), 1000 * 1e18);
        assertEq(lending.debtOwed(user, address(tokenB)), 1000 * 1e18);
        assertEq(lending.getRemainingBorrowCapacity(user), 2000 * 1e18);

        // Second borrow: 2000 TokenB
        lending.borrow(address(tokenB), 2000 * 1e18);
        assertEq(lending.debtOwed(user, address(tokenB)), 3000 * 1e18);
        assertEq(lending.getRemainingBorrowCapacity(user), 0);

        // Third borrow: 1 TokenB -> should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.ExceedsBorrowCapacity.selector,
                1 * 1e18,
                0
            )
        );
        lending.borrow(address(tokenB), 1 * 1e18);
        vm.stopPrank();
    }

    function test_Borrow_WithUserParam_Unauthorized() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(Lending.Unauthorized.selector);
        lending.borrow(user, address(tokenB), 100 * 1e18);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                               FUZZ TESTING                                 */
    /* -------------------------------------------------------------------------- */

    function testFuzz_BorrowCapacityCheck(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1e18, 1_000_000 * 1e18);
        borrowAmount = bound(borrowAmount, 1e18, 2_000_000 * 1e18);

        vm.startPrank(owner);
        lending.configureToken(address(tokenA), 5000, true); // 50% CF
        lending.configureTokenPrice(address(tokenA), 100 * 1e18); // $100 per tokenA
        lending.configureToken(address(tokenB), 5000, true);
        lending.configureTokenPrice(address(tokenB), 10 * 1e18); // $10 per tokenB
        vm.stopPrank();

        tokenA.mint(user, depositAmount);
        vm.startPrank(user);
        tokenA.approve(address(lending), depositAmount);
        lending.depositCollateral(depositAmount, address(tokenA));
        vm.stopPrank();

        uint256 totalCollateralValue = (depositAmount * 100 * 1e18) / 1e18;
        uint256 expectedCapacity = (totalCollateralValue * 5000) / 10000;
        uint256 requestedBorrowValue = (borrowAmount * 10 * 1e18) / 1e18;

        if (requestedBorrowValue <= expectedCapacity) {
            assertTrue(lending.checkBorrowCapacity(user, address(tokenB), borrowAmount));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Lending.ExceedsBorrowCapacity.selector,
                    requestedBorrowValue,
                    expectedCapacity
                )
            );
            lending.checkBorrowCapacity(user, address(tokenB), borrowAmount);
        }
    }
}

// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}


library platformCalculation {
    function calculateCollateralValue(
        uint256 amount,
        uint256 price
    ) internal pure returns (uint256) {
        return (amount * price) / 1e18;
    }

    function calculateBorrowCapacity(
        uint256 collateralValue,
        uint256 collateralFactorBps,
        uint256 maxBps
    ) internal pure returns (uint256) {
        return (collateralValue * collateralFactorBps) / maxBps;
    }
    function calculateInterest(uint256 principal, uint256 rate, uint256 time, uint256 timeDenominator) internal pure returns (uint256) {
        return (principal * rate * time) / timeDenominator;
    }
}

contract Lending {
    address public owner;

    uint256 public constant MAXIMUM_PRICE_AGE = 5 days;
    uint256 public constant MAX_COLLATERAL_FACTOR_BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct TokenConfig {
        bool enabled;
        uint256 collateralFactorBps;
        address tokenAddress;
        uint256 annualInterestRateBps;

    }

    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    struct DebtPosition {
        uint256 principal;      
       uint256 lastAccruedAt;
    }

    mapping(address => TokenConfig) public config;
    mapping(address => PriceData) public price;

    address[] public supportedTokens;

    mapping(address => mapping(address => uint256)) public collateralBalance; 
    mapping(address => mapping(address => DebtPosition)) public debtPositions;

    /*---------------Errors-----------------*/
    error NotOwner();
    error InvalidPrice();
    error PriceNotFound();
    error StalePrice();
    error TokenNotFound();
    error InvalidCollateralFactor();
    error TokenDisabled();
    error TransferFailed();
    error ExceedsBorrowCapacity(uint256 requested, uint256 available);
    error InvalidAmount();
    error Unauthorized();

    /*---------------Events-----------------*/
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

    event Repay(
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function configureToken(
        address _token,
        uint256 _collateralFactorBps,
        bool _enabled
    ) external onlyOwner {
        configureToken(_token, _collateralFactorBps, _enabled, 1000);
    }

    function configureToken(
        address _token,
        uint256 _collateralFactorBps,
        bool _enabled,
        uint256 _annualInterestRateBps
    ) public onlyOwner {
        if (_token == address(0)) revert TokenNotFound();

        if (_collateralFactorBps > MAX_COLLATERAL_FACTOR_BPS) {
            revert InvalidCollateralFactor();
        }

        if (config[_token].tokenAddress == address(0)) {
            supportedTokens.push(_token);
        }

        config[_token] = TokenConfig({
            enabled: _enabled,
            collateralFactorBps: _collateralFactorBps,
            tokenAddress: _token,
            annualInterestRateBps: _annualInterestRateBps
        });

        emit TokenConfigured(
            _token,
            _collateralFactorBps,
            _enabled,
            block.timestamp
        );
    }

    function configureTokenPrice(
        address _token,
        uint256 _price
    ) external onlyOwner {
        if (_price == 0) revert InvalidPrice();

        if (config[_token].tokenAddress == address(0)) {
            revert TokenNotFound();
        }

        price[_token] = PriceData({
            price: _price,
            updatedAt: block.timestamp
        });

        emit PriceConfigured(_token, _price, block.timestamp);
    }

    function getLatestPrice(
        address _token
    ) public view returns (uint256) {
        PriceData memory data = price[_token];

        if (data.price == 0) {
            revert PriceNotFound();
        }

        if (block.timestamp - data.updatedAt > MAXIMUM_PRICE_AGE) {
            revert StalePrice();
        }

        return data.price;
    }

    function depositCollateral(
        uint256 _amount,
        address _token
    ) external {
        TokenConfig memory tokenConfig = config[_token];

        if (tokenConfig.tokenAddress == address(0)) {
            revert TokenNotFound();
        }

        if (!tokenConfig.enabled) {
            revert TokenDisabled();
        }

        bool success = IERC20(_token).transferFrom(
            msg.sender,
            address(this),
            _amount
        );

        if (!success) {
            revert TransferFailed();
        }

        collateralBalance[msg.sender][_token] += _amount;

        emit CollateralDeposited(
            msg.sender,
            _token,
            _amount
        );
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function getCollateralValue(
        address _user,
        address _token
    ) public view returns (uint256) {
        uint256 amount = collateralBalance[_user][_token];
        if (amount == 0) return 0;

        uint256 tokenPrice = getLatestPrice(_token);
        return platformCalculation.calculateCollateralValue(amount, tokenPrice);
    }

    function getTotalCollateralValue(
        address _user
    ) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            totalValue += getCollateralValue(_user, token);
        }
    }

    function getBorrowingCapacity(
        address _user
    ) public view returns (uint256 totalCapacity) {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            TokenConfig memory tokenConfig = config[token];

            if (tokenConfig.enabled && collateralBalance[_user][token] > 0) {
                uint256 collateralVal = getCollateralValue(_user, token);
                totalCapacity += platformCalculation.calculateBorrowCapacity(
                    collateralVal,
                    tokenConfig.collateralFactorBps,
                    MAX_COLLATERAL_FACTOR_BPS
                );
            }
        }
    }

    function debtOwed(address _user, address _token) external view returns (uint256) {
        return getAccruedDebt(_user, _token);
    }

    function getTotalDebtValue(
        address _user
    ) public view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 debt = getAccruedDebt(_user, token);
            if (debt > 0) {
                uint256 tokenPrice = getLatestPrice(token);
                totalDebt += platformCalculation.calculateCollateralValue(debt, tokenPrice);
            }
        }
    }

    function getRemainingBorrowCapacity(
        address _user
    ) public view returns (uint256) {
        uint256 maxCapacity = getBorrowingCapacity(_user);
        uint256 totalDebt = getTotalDebtValue(_user);

        if (maxCapacity <= totalDebt) {
            return 0;
        }

        return maxCapacity - totalDebt;
    }

    function checkBorrowCapacity(
        address _user,
        address _borrowToken,
        uint256 _borrowAmount
    ) public view returns (bool) {
        if (_borrowAmount == 0) return true;

        uint256 borrowTokenPrice = getLatestPrice(_borrowToken);
        uint256 requestedValue = platformCalculation.calculateCollateralValue(
            _borrowAmount,
            borrowTokenPrice
        );
        uint256 remainingCapacity = getRemainingBorrowCapacity(_user);

        if (requestedValue > remainingCapacity) {
            revert ExceedsBorrowCapacity(requestedValue, remainingCapacity);
        }

        return true;
    }

    function borrow(
        address _user,
        address _asset,
        uint256 _amount
    ) external {
        if (msg.sender != _user) revert Unauthorized();
        _executeBorrow(_user, _asset, _amount);
    }

    function borrow(
        address _asset,
        uint256 _amount
    ) external {
        _executeBorrow(msg.sender, _asset, _amount);
    }

    function _executeBorrow(
        address _user,
        address _asset,
        uint256 _amount
    ) internal {
        if (_amount == 0) revert InvalidAmount();

        TokenConfig memory tokenConfig = config[_asset];
        if (tokenConfig.tokenAddress == address(0)) {
            revert TokenNotFound();
        }
        if (!tokenConfig.enabled) {
            revert TokenDisabled();
        }

        uint256 assetPrice = getLatestPrice(_asset);

        uint256 requestedValue = platformCalculation.calculateCollateralValue(
            _amount,
            assetPrice
        );
        uint256 remainingCapacity = getRemainingBorrowCapacity(_user);

        if (requestedValue > remainingCapacity) {
            revert ExceedsBorrowCapacity(requestedValue, remainingCapacity);
        }

        // 1. Accrue any existing interest first
        _accrueInterest(_user, _asset);

        // 2. Add new borrow amount to principal
        debtPositions[_user][_asset].principal += _amount;

        // 3. Transfer borrowed asset to user
        bool success = IERC20(_asset).transfer(_user, _amount);
        if (!success) {
            revert TransferFailed();
        }

        emit Borrow(_user, _asset, _amount);
    }

    function getAccruedDebt(address _user, address _token) public view returns (uint256) {
        DebtPosition memory pos = debtPositions[_user][_token];
        if (pos.principal == 0) return 0;

        uint256 timeElapsed = block.timestamp - pos.lastAccruedAt;
        uint256 interestRateBps = config[_token].annualInterestRateBps;

        uint256 interest = (pos.principal * interestRateBps * timeElapsed) 
            / (BPS_DENOMINATOR * SECONDS_PER_YEAR);

        return pos.principal + interest;
    }

    function _accrueInterest(address _user, address _token) internal {
        DebtPosition storage pos = debtPositions[_user][_token];
        
        if (pos.principal > 0 && pos.lastAccruedAt > 0) {
            uint256 currentDebt = getAccruedDebt(_user, _token);
            pos.principal = currentDebt; 
        }
        
        pos.lastAccruedAt = block.timestamp;
    }

    function repay(address _asset, uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();

        TokenConfig memory tokenConfig = config[_asset];
        if (tokenConfig.tokenAddress == address(0)) {
            revert TokenNotFound();
        }

        _accrueInterest(msg.sender, _asset);

        DebtPosition storage pos = debtPositions[msg.sender][_asset];
        uint256 totalDebt = pos.principal;
        if (totalDebt == 0) revert InvalidAmount();
        
        uint256 repayAmount = _amount > totalDebt ? totalDebt : _amount;

        pos.principal = totalDebt - repayAmount;
        
        if (pos.principal == 0) {
            pos.lastAccruedAt = 0;
        }

        bool success = IERC20(_asset).transferFrom(msg.sender, address(this), repayAmount);
        if (!success) {
            revert TransferFailed();
        }

        emit Repay(msg.sender, _asset, repayAmount);
    }
}
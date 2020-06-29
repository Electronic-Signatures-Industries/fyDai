pragma solidity ^0.6.2;

import "@hq20/contracts/contracts/access/AuthorizedAccess.sol";
import "@hq20/contracts/contracts/math/DecimalMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IChai.sol";
import "./interfaces/IGasToken.sol";
import "./interfaces/IDealer.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IYDai.sol";
import "./Constants.sol";
import "./UserProxy.sol";
// import "@nomiclabs/buidler/console.sol";

/// @dev A dealer takes collateral and issues yDai.
contract Dealer is IDealer, AuthorizedAccess(), UserProxy(), Constants {
    using SafeMath for uint256;
    using DecimalMath for uint256;
    using DecimalMath for uint8;

    event Posted(bytes32 indexed collateral, address indexed user, uint256 amount);
    event Borrowed(bytes32 indexed collateral, uint256 indexed maturity, address indexed user, uint256 amount);

    ITreasury internal _treasury;
    IERC20 internal _dai;
    IGasToken internal _gasToken;
    mapping(bytes32 => IERC20) internal _token;                       // Weth or Chai
    mapping(bytes32 => IOracle) internal _oracle;                     // WethOracle or ChaiOracle
    mapping(uint256 => IYDai) public override series;      // YDai series, indexed by maturity
    uint256[] internal seriesIterator;            // We need to know all the series

    mapping(bytes32 => mapping(address => uint256)) public override posted;    // In Weth or Chai
    mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) public debtYDai;  // By series, in yDai

    bool public live = true;

    constructor (
        address treasury_,
        address dai_,
        address weth_,
        address wethOracle_,
        address chai_,
        address chaiOracle_,
        address gasToken_
    ) public {
        _treasury = ITreasury(treasury_);
        _dai = IERC20(dai_);
        _token[WETH] = IERC20(weth_);
        _oracle[WETH] = IOracle(wethOracle_);
        _token[CHAI] = IERC20(chai_);
        _oracle[CHAI] = IOracle(chaiOracle_);
        _gasToken = IGasToken(gasToken_);
    }

    modifier onlyLive() {
        require(live == true, "Dealer: Not available during shutdown");
        _;
    }

    modifier validSeries(uint256 maturity) {
        require(
            containsSeries(maturity),
            "Dealer: Unrecognized series"
        );
        _;
    }

    modifier validCollateral(bytes32 collateral) {
        require(
            collateral == WETH || collateral == CHAI,
            "Dealer: Unrecognized collateral"
        );
        _;
    }

    /// @dev Disables post, withdraw, borrow and repay. To be called only by shutdown management contracts.
    function shutdown() public override onlyAuthorized("Dealer: Not Authorized") {
        live = false;
    }

    /// @dev Returns if a series has been added to the Dealer, for a given series identified by maturity
    function containsSeries(uint256 maturity) public view returns (bool) {
        return address(series[maturity]) != address(0);
    }

    /// @dev Adds an yDai series to this Dealer
    function addSeries(address yDaiContract) public onlyOwner {
        uint256 maturity = IYDai(yDaiContract).maturity();
        require(
            !containsSeries(maturity),
            "Dealer: Series already added"
        );
        series[maturity] = IYDai(yDaiContract);
        seriesIterator.push(maturity);
    }

    /// @dev Returns the total debt of the yDai system, across all series, in dai
    // TODO: Test
    function systemDebt() public override returns (uint256) {
        uint256 totalDebt;
        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            IYDai yDai = series[seriesIterator[i]];
            totalDebt = totalDebt + IERC20(address(yDai)).totalSupply().muld(yDai.rateGrowth(), RAY);
        } // We don't expect hundreds of maturities per dealer
        return totalDebt;
    }


    /// @dev Returns the dai equivalent of an yDai amount, for a given series identified by maturity
    function inDai(uint256 maturity, uint256 yDaiAmount) public returns (uint256) {
        // if (now >= maturity) { // TODO: Consider using for gas savings
        if (series[maturity].isMature()){
            return yDaiAmount.muld(series[maturity].rateGrowth(), RAY);
        }
        else {
            return yDaiAmount;
        }
    }

    /// @dev Returns the yDai equivalent of a dai amount, for a given series identified by maturity
    function inYDai(uint256 maturity, uint256 daiAmount) public returns (uint256) {
        // if (now >= maturity) { // TODO: Consider using for gas savings
        if (series[maturity].isMature()){
            return daiAmount.divd(series[maturity].rateGrowth(), RAY);
        }
        else {
            return daiAmount;
        }
    }

    /// @dev Return debt in dai of an user, for a given collateral and series identified by maturity
    //
    //                        rate_now
    // debt_now = debt_mat * ----------
    //                        rate_mat
    //
    function debtDai(bytes32 collateral, uint256 maturity, address user) public returns (uint256) {
        return inDai(maturity, debtYDai[collateral][maturity][user]);
    }

    /// @dev Returns the total debt of an user, for a given collateral, across all series, in Dai
    function totalDebtDai(bytes32 collateral, address user) public override returns (uint256) {
        uint256 totalDebt;
        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            // TODO: Skip next line if debtYDai[collateral][maturity][user] == 0
            totalDebt = totalDebt + debtDai(collateral, seriesIterator[i], user);
        } // We don't expect hundreds of maturities per dealer
        return totalDebt;
    }

    /// @dev Returns the total debt of an user, for a given collateral, across all series, in yDai
    function totalDebtYDai(bytes32 collateral, address user) public view override returns (uint256) {
        uint256 totalDebt;
        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            totalDebt = totalDebt + debtYDai[collateral][seriesIterator[i]][user];
        } // We don't expect hundreds of maturities per dealer
        return totalDebt;
    }

    /// @dev Maximum borrowing power of an user in dai for a given collateral
    //
    // powerOf[user](wad) = posted[user](wad) * oracle.price()(ray)
    //
    function powerOf(bytes32 collateral, address user) public returns (uint256) {
        // dai = price * collateral
        return posted[collateral][user].muld(_oracle[collateral].price(), RAY);
    }

    /// @dev Return if the borrowing power for a given collateral of an user is equal or greater than its debt for the same collateral
    function isCollateralized(bytes32 collateral, address user) public override returns (bool) {
        return powerOf(collateral, user) >= totalDebtDai(collateral, user);
    }

    /// @dev Takes collateral _token from `from` address, and credits it to `to` collateral account.
    // from --- Token ---> us(to)
    function post(bytes32 collateral, address from, address to, uint256 amount)
        public override 
        validCollateral(collateral)
        onlyHolderOrProxy(from, "Dealer: Only Holder Or Proxy")
        onlyLive
    {
        require(
            _token[collateral].transferFrom(from, address(_treasury), amount),
            "Dealer: Collateral transfer fail"
        );

        if (collateral == WETH){ // TODO: Refactor Treasury to be `push(collateral, amount)`
            _treasury.pushWeth();                          // Have Treasury process the weth
        } else if (collateral == CHAI) {
            _treasury.pushChai();
        }
        
        if (posted[collateral][to] == 0 && amount >= 0) {
            lockBond(10);
        }
        posted[collateral][to] = posted[collateral][to].add(amount);
        emit Posted(collateral, to, posted[collateral][to]);
    }

    /// @dev Returns collateral to `to` address, taking it from `from` collateral account.
    // us(from) --- Token ---> to
    function withdraw(bytes32 collateral, address from, address to, uint256 amount)
        public override
        validCollateral(collateral)
        onlyHolderOrProxy(from, "Dealer: Only Holder Or Proxy")
        onlyLive
    {
        posted[collateral][from] = posted[collateral][from].sub(amount); // Will revert if not enough posted

        require(
            isCollateralized(collateral, from),
            "Dealer: Too much debt"
        );

        if (collateral == WETH){
            _treasury.pullWeth(to, amount);
        } else if (collateral == CHAI) {
            _treasury.pullChai(to, amount);
        }

        if (posted[collateral][from] == 0 && amount >= 0) {
            returnBond(10);
        }
        emit Posted(collateral, from, posted[collateral][to]);
    }

    /// @dev Mint yDai for a given series for address `to` by locking its market value in collateral, user debt is increased in the given collateral.
    //
    // posted[user](wad) >= (debtYDai[user](wad)) * amount (wad)) * collateralization (ray)
    //
    // us --- yDai ---> user
    // debt++
    function borrow(bytes32 collateral, uint256 maturity, address to, uint256 yDaiAmount)
        public
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrProxy(to, "Dealer: Only Holder Or Proxy")
        onlyLive
    {
        require(
            series[maturity].isMature() != true,
            "Dealer: No mature borrow"
        );

        if (debtYDai[collateral][maturity][to] == 0 && yDaiAmount >= 0) {
            lockBond(10);
        }
        debtYDai[collateral][maturity][to] = debtYDai[collateral][maturity][to].add(yDaiAmount);

        require(
            isCollateralized(collateral, to),
            "Dealer: Too much debt"
        );
        series[maturity].mint(to, yDaiAmount);
        emit Borrowed(collateral, maturity, to, debtYDai[collateral][maturity][to]);
    }

    /// @dev Burns yDai of a given series from `from` address, user debt is decreased for the given collateral and yDai series.
    //                                                  debt_nominal
    // debt_discounted = debt_nominal - repay_amount * ---------------
    //                                                  debt_now
    //
    // user --- yDai ---> us
    // debt--
    function repayYDai(bytes32 collateral, uint256 maturity, address from, uint256 yDaiAmount)
        public
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrProxy(from, "Dealer: Only Holder Or Proxy")
        onlyLive
    {

        (uint256 toRepay, uint256 debtDecrease) = repayProportion(collateral, maturity, from, yDaiAmount);
        series[maturity].burn(from, toRepay);
        debtYDai[collateral][maturity][from] = debtYDai[collateral][maturity][from].sub(debtDecrease);
        if (debtYDai[collateral][maturity][from] == 0 && debtDecrease >= 0) {
            returnBond(10);
        }
        emit Borrowed(collateral, maturity, from, debtYDai[collateral][maturity][from]);
    }

    /// @dev Takes dai from `from` address, user debt is decreased for the given collateral and yDai series.
    //                                                  debt_nominal
    // debt_discounted = debt_nominal - repay_amount * ---------------
    //                                                  debt_now
    //
    // user --- dai ---> us
    // debt--
    function repayDai(bytes32 collateral, uint256 maturity, address from, uint256 daiAmount)
        public
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrProxy(from, "Dealer: Only Holder Or Proxy")
        onlyLive
    {
        (uint256 toRepay, uint256 debtDecrease) = repayProportion(collateral, maturity, from, inYDai(maturity, daiAmount));
        require(
            _dai.transferFrom(from, address(_treasury), toRepay),  // Take dai from user to Treasury
            "Dealer: Dai transfer fail"
        );

        _treasury.pushDai();                                      // Have Treasury process the dai
        debtYDai[collateral][maturity][from] = debtYDai[collateral][maturity][from].sub(debtDecrease);
        if (debtYDai[collateral][maturity][from] == 0 && debtDecrease >= 0) {
            returnBond(10);
        }
        emit Borrowed(collateral, maturity, from, debtYDai[collateral][maturity][from]);
    }

    /// @dev Erases all collateral and debt for an user.
    function erase(bytes32 collateral, address user)
        public override
        validCollateral(collateral)
        onlyAuthorized("Dealer: Not Authorized")
        returns (uint256, uint256)
    {
        uint256 debt;
        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            debt = debt + debtDai(collateral, seriesIterator[i], user);
            delete debtYDai[collateral][seriesIterator[i]][user];
            emit Borrowed(collateral, seriesIterator[i], user, 0);
        } // We don't expect hundreds of maturities per dealer
        uint256 tokens = posted[collateral][user];
        delete posted[collateral][user];
        emit Posted(collateral, user, 0);
        
        returnBond((seriesIterator.length + 1) * 10); // 10 per series, and 10 for the collateral
        return (tokens, debt);
    }

    /// @dev Removes collateral and debt for an user.
    function grab(bytes32 collateral, address user, uint256 daiAmount, uint256 tokenAmount)
        public override
        validCollateral(collateral)
        onlyAuthorized("Dealer: Not Authorized")
    {

        posted[collateral][user] = posted[collateral][user].sub(
            tokenAmount,
            "Dealer: Not enough collateral"
        );
        if (posted[collateral][user] == 0){
            returnBond(10);
        }

        uint256 grabbed;
        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            uint256 maturity = seriesIterator[i];
            uint256 thisGrab = Math.min(debtDai(collateral, maturity, user), daiAmount.sub(grabbed));
            grabbed = grabbed.add(thisGrab); // SafeMath shouldn't be needed
            debtYDai[collateral][maturity][user] = debtYDai[collateral][maturity][user].sub(inYDai(maturity, thisGrab)); // SafeMath shouldn't be needed
            if (debtYDai[collateral][maturity][user] == 0){
                returnBond(10);
            }
            if (grabbed == daiAmount) break;
        } // We don't expect hundreds of maturities per dealer
        require(
            grabbed == daiAmount,
            "Dealer: Not enough user debt"
        );
    }


    /// @dev Calculates the amount to repay and the amount by which to reduce the debt for a given collateral and series
    function repayProportion(bytes32 collateral, uint256 maturity, address user, uint256 yDaiAmount)
        internal returns(uint256, uint256) {
        uint256 toRepay = Math.min(yDaiAmount, debtDai(collateral, maturity, user));
        // TODO: Check if this can be taken from DecimalMath.sol
        // uint256 debtProportion = debtYDai[user].mul(RAY.unit())
        //     .divdr(debtDai(user).mul(RAY.unit()), RAY);
        uint256 debtProportion = divdrup( // TODO: Check it works if we are not rounding.
            debtYDai[collateral][maturity][user].mul(RAY.unit()),
            debtDai(collateral, maturity, user).mul(RAY.unit()),
            RAY
        );
        return (toRepay, toRepay.muld(debtProportion, RAY));
    }

    /// @dev Locks a liquidation bond in gas tokens
    function lockBond(uint256 value) internal {
        if (!_gasToken.transferFrom(msg.sender, address(this), value)) {
            _gasToken.mint(value);
        }
    }

    /// @dev Frees a liquidation bond in gas tokens
    function returnBond(uint256 value) internal {
        _gasToken.transfer(msg.sender, value);
    }

    /// @dev Divides x between y, rounding up to the closest representable number.
    /// Assumes x and y are both fixed point with `decimals` digits.
     // TODO: Check if this needs to be taken from DecimalMath.sol
    function divdrup(uint256 x, uint256 y, uint8 decimals)
        internal pure returns (uint256)
    {
        uint256 z = x.mul((decimals + 1).unit()).div(y);
        if (z % 10 > 0) return z / 10 + 1;
        else return z / 10;
    }
}
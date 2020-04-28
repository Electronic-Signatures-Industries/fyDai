pragma solidity ^0.6.2;

import "@hq20/contracts/contracts/math/DecimalMath.sol";
import "@hq20/contracts/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/IDaiJoin.sol";
import "./interfaces/IGemJoin.sol";
import "./interfaces/IVat.sol";
import "./interfaces/IPot.sol";
import "./Constants.sol";


/// @dev Treasury is the bottom layer that moves all assets.
contract Treasury is Ownable, Constants {
    using DecimalMath for uint256;
    using DecimalMath for int256;
    using DecimalMath for uint8;

    IERC20 public weth;
    IERC20 public dai;
    // Maker join contracts:
    // https://github.com/makerdao/dss/blob/master/src/join.sol
    IGemJoin public wethJoin;
    IDaiJoin public daiJoin;
    // Maker vat contract:
    IVat public vat;
    IPot public pot;

    int256 daiBalance; // Could this be retrieved as dai.balanceOf(address(this)) - something?
    // uint256 ethBalance; // This can be retrieved as weth.balanceOf(address(this))
    bytes32 collateralType = "ETH-A";

    // TODO: Move to Constants.sol
    // Fixed point256 precisions from MakerDao
    uint8 constant public wad = 18;
    uint8 constant public ray = 27;
    uint8 constant public rad = 45;

    /// @dev Moves Eth collateral from user into Treasury controlled Maker Eth vault
    function post(address from, uint256 amount) public {
        require(
            weth.transferFrom(from, address(this), amount),
            "YToken: WETH transfer fail"
        );
        weth.approve(address(wethJoin), amount);
        wethJoin.join(address(this), amount); // GemJoin reverts if anything goes wrong.
        // All added collateral should be locked into the vault
        // collateral to add - wad
        int256 dink = amount.toInt256();
        // Normalized Dai to receive - wad
        int256 dart = 0;
        // frob alters Maker vaults
        vat.frob(
            collateralType,
            address(this),
            address(this),
            address(this),
            dink,
            dart
        ); // `vat.frob` reverts on failure
    }

    /// @dev Moves Eth collateral from Treasury controlled Maker Eth vault back to user
    /// TODO: This function requires authorization to use
    function withdraw(address receiver, uint256 amount) public {
        // Remove collateral from vault
        // collateral to add - wad
        int256 dink = -amount.toInt256();
        // Normalized Dai to receive - wad
        int256 dart = 0;
        // frob alters Maker vaults
        vat.frob(
            collateralType,
            address(this),
            address(this),
            address(this),
            dink,
            dart
        ); // `vat.frob` reverts on failure
        wethJoin.exit(receiver, amount); // `GemJoin` reverts on failures
    }

    /// @dev Moves Dai from user into Treasury controlled Maker Dai vault
    function repay(address source, uint256 amount) public {
        require(
            dai.transferFrom(source, address(this), amount),
            "YToken: DAI transfer fail"
        ); // TODO: Check dai behaviour on failed transfers
        (, uint256 normalizedDebt) = vat.urns(collateralType, address(this));
        if (normalizedDebt > 0){
            // repay as much debt as possible
            (, uint256 rate,,,) = vat.ilks(collateralType);
            // Normalized Dai to receive - wad
            int256 dart = int256(amount.divd(rate, ray)); // `amount` and `rate` are positive
            maturityRate = Math.min(dart, ray.unit()); // only repay up to total in
            _repayDai(dart);
        } else {
            // put funds in the DSR
            _lockDai();
        }


    }

    /// @dev moves Dai from Treasury to user, borrowing from Maker DAO if not enough present.
    /// TODO: This function requires authorization to use
    function disburse(address receiver, uint256 amount) public {
        uint256 chi = pot.chi();
        uint256 normalizedBalance = pot.pie(address(this));
        uint256 balance = normalizedBalance.muld(chi, ray);
        if (balance > toSend) {
            //send funds directly
            uint256 normalizedAmount = amount.divd(chi, ray);
            _freeDai(normalizedAmount);
            require(
                dai.transfer(receiver, amount),
                "YToken: DAI transfer fail"
            ); // TODO: Check dai behaviour on failed transfers
        } else {
            //borrow funds and send them
            _borrowDai(receiver, amount);
        }
    }

    /// @dev Mint an `amount` of Dai
    function _borrowDai(address receiver, uint256 amount) private {
        // Add Dai to vault
        // collateral to add - wad
        int256 dink = 0; // Delta ink, change in collateral balance
        // Normalized Dai to receive - wad
        (, rate,,,) = vat.ilks("ETH-A"); // Retrieve the MakerDAO stability fee
        // collateral to add -- all collateral should already be present
        int256 dart = -amount.divd(rate, ray).toInt256(); // Delta art, change in dai debt
        // Normalized Dai to receive - wad
        // frob alters Maker vaults
        vat.frob(
            collateralType,
            address(this),
            address(this),
            address(this),
            dink,
            dart
        ); // `vat.frob` reverts on failure
        daiJoin.exit(receiver, amount); // `daiJoin` reverts on failures
    }

        /// @dev Moves Dai from user into Treasury controlled Maker Dai vault
    function _repayDai(uint256 dart) private {
        // TODO: Check dai behaviour on failed transfers
        daiJoin.join(address(this), amount);
        // Add Dai to vault
        // collateral to add - wad
        int256 dink = 0;
        // frob alters Maker vaults
        vat.frob(
            collateralType,
            address(this),
            address(this),
            address(this),
            dink,
            dart
        ); // `vat.frob` reverts on failure
    }

    /// @dev lock all Dai in the DSR
    function _lockDai() private {
        uint256 balance = dai.balanceOf(address(this));
        uint256 chi = pot.chi();
        uint256 normalizedAmount = balance.divd(chi, ray);
        pot.join(normalizedAmount);
    }

    /// @dev remove Dai from the DSR
    function _freeDai(uint256 amount) private {
        uint256 chi = pot.chi();
        uint256 normalizedAmount = amount.divd(chi, ray);
        pot.exit(normalizedAmount);
    }
}
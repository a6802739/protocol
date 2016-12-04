pragma solidity ^0.4.4;

import "./dependencies/ERC20.sol";
import "./dependencies/ERC20Protocol.sol";
import "./dependencies/Owned.sol";
import "./dependencies/SafeMath.sol";
import "./tokens/EtherToken.sol";
import "./router/RegistrarProtocol.sol";
import "./router/PriceFeedProtocol.sol";
import "./router/ManagementFeeProtocol.sol";
import "./router/PerformanceFeeProtocol.sol";

contract Shares is ERC20 {}

/// @title Core Contract
/// @author Melonport AG <team@melonport.com>
contract Core is Shares, SafeMath, Owned {

    // TYPES

    struct Manager {
        uint capital;
        uint delta;
        bool received_first_investment;
        uint evaluation_interval;  // Calcuate delta for fees every x days
    }
    // Analytics of last time creation/annihilation of shares happened.
    struct Analytics {
        uint nav;
        uint delta;
        uint timestamp;
    }
    struct Modules {
        EtherToken ether_token;
        RegistrarProtocol registrar;
        ManagementFeeProtocol management_fee;
        PerformanceFeeProtocol performance_fee;
    }

    // FIELDS

    Manager manager;
    Analytics analytics;
    Modules module;

    uint public sumInvested;
    uint public sumWithdrawn;
    uint public sumAssetsBought;
    uint public sumAssetsSold;
    uint public sharePrice = 1 ether;

    // EVENTS

    event SharesCreated(address buyer, uint numShares, uint sharePrice);
    event SharesAnnihilated(address seller, uint numShares, uint sharePrice);
    event Refund(address to, uint value);
    event LogString(string text);
    event LogInt(string text, uint value);
    event LogBool(string text, bool value);

    // MODIFIERS

    modifier msg_value_at_least(uint x) {
        assert(msg.value >= x);
        _;
    }

    modifier msg_value_past(uint x) {
        assert(msg.value > x);
        _;
    }

    modifier not_zero(uint x) {
        assert(x != 0);
        _;
    }

    modifier balances_msg_sender_at_least(uint x) {
        assert(balances[msg.sender] >= x);
        _;
    }

    // CONSTANT METHDOS

    /// Post: Calculate Share Price in Wei
    function calcSharePrice() constant returns (uint) { return calcDelta(); }

    /// Pre:
    /// Post: Delta as a result of current and previous NAV
    function calcDelta() constant returns (uint delta) {
        uint nav = calcNAV();
        // Set delta
        if (analytics.nav == 0) {
            delta = 1 ether; // First investment not made
        } else if (nav == 0) {
            delta = 1 ether; // First investment made; All funds withdrawn
        } else {
            delta = (analytics.delta * nav) / analytics.nav; // First investment made; Not all funds withdrawn
        }
        // Update Analytics
        analytics.delta = delta;
        analytics.nav = nav;
        analytics.timestamp = now;
    }

    /// Pre:
    /// Post: Portfolio Net Asset Value in Wei, managment and performance fee allocated
    function calcNAV() constant returns (uint nav) {
        uint managementFee = 0;
        uint performanceFee = 0;
        nav = calcGAV() - managementFee - performanceFee;
    }

    /// Pre: Precision in Token must be equal to precision in PriceFeed for all entries in Registrar
    /// Post: Portfolio Gross Asset Value in Wei
    function calcGAV() constant returns (uint gav) {
        /* Rem:
         *  The current Investment (Withdrawal) is not yet stored in the
         *  sumInvested (sumWithdrawn) field.
         * Rem 2:
         *  Since by convention the first asset represents Ether, and the prices
         *  are given in Ether the first price is always equal to one.
         * Rem 3:
         *  Assets need to be linked to the right price feed
         * Rem 4:
         *  Price Input Unit: [Wei/(Asset * 10**(uint(precision)))]
         *  Holdings Input Unit: [Asset * 10**(uint(precision)))]
         *  with 0 <= precision <= 18 and precision is a natural number.
         */
        gav = module.ether_token.balanceOf(this) * 1; // EtherToken as Asset
        uint numAssignedAssets = module.registrar.numAssignedAssets();
        for (uint i = 0; i < numAssignedAssets; ++i) {
            ERC20Protocol ERC20 = ERC20Protocol(address(module.registrar.assetAt(i)));
            uint holdings = ERC20.balanceOf(address(this)); // Asset holdings
            PriceFeedProtocol Price = PriceFeedProtocol(address(module.registrar.priceFeedsAt(i)));
            uint price = Price.getPrice(address(module.registrar.assetAt(i))); // Asset price
            gav += holdings * price; // Sum up product of asset holdings and asset prices
        }
    }

    // NON-CONSTANT METHODS

    function Core(
        address addrEtherToken,
        address addrRegistrar
    ) {
        analytics.nav = 0;
        analytics.delta = 1 ether;
        analytics.timestamp = now;

        module.ether_token = EtherToken(addrEtherToken);
        module.registrar = RegistrarProtocol(addrRegistrar);
    }

    // Invest in a fund by creating shares
    /* Note:
     *  This is can be seen as a none persistent all or nothing limit order, where:
     *  quantity == quantitiyShares and
     *  amount == msg.value (amount investor is willing to pay for the req. quantity)
     */
    function createShares(uint wantedShares)
        payable
        msg_value_past(0)
        not_zero(wantedShares)
        returns (bool)
    {
        sharePrice = calcSharePrice();
        uint sentFunds = msg.value;

        // Check if enough funds sent for requested quantity of shares.
        uint intendedInvestment = sharePrice * wantedShares / (1 ether);
        if (intendedInvestment <= sentFunds) {
            // Create Shares
            balances[msg.sender] = safeAdd(balances[msg.sender], wantedShares);
            totalSupply = safeAdd(totalSupply, wantedShares);
            sumInvested = safeAdd(sumInvested, intendedInvestment);
            analytics.nav = safeAdd(analytics.nav, intendedInvestment); // Bookkeeping
            if (!manager.received_first_investment) {
                manager.received_first_investment = true; // Flag first investment as happened
            }
            // Store Ether in EtherToken contract
            assert(module.ether_token.deposit.value(intendedInvestment)());
            SharesCreated(msg.sender, wantedShares, sharePrice);
        }
        // Refund remainder
        if (intendedInvestment < sentFunds) {
            uint remainder = sentFunds - intendedInvestment;
            assert(msg.sender.send(remainder));
            Refund(msg.sender, remainder);
        }

        return true;
    }

    /// Withdraw from a fund by annihilating shares
    function annihilateShares(uint offeredShares, uint wantedAmount)
        balances_msg_sender_at_least(offeredShares)
        not_zero(wantedAmount)
        not_zero(offeredShares)
        returns (bool)
    {
        sharePrice = calcSharePrice();

        /* TODO implement forced withdrawal
         *  Via registrar contract and exchange
         */
        uint ethBalance = this.balance;
        if (wantedAmount > ethBalance)
            throw;

        // Check if enough shares offered for requested amount of funds.
        uint curSumWithdrawn = 0;
        uint intendedOffering = sharePrice * offeredShares / (1 ether);
        if (wantedAmount <= intendedOffering) {
            // Annihilate Shares
            balances[msg.sender] -= offeredShares;
            totalSupply -= offeredShares;
            curSumWithdrawn = intendedOffering;
            sumWithdrawn += curSumWithdrawn;
            // Bookkeeping
            analytics.nav -= curSumWithdrawn;
            // Send Funds
            /*assert(module.ether_token.withdraw(intendedInvestment));*/
            if(!msg.sender.send(curSumWithdrawn)) throw;
            SharesAnnihilated(msg.sender, offeredShares, sharePrice);
        }
        // Refund remainder
        if (wantedAmount < intendedOffering) {
            uint remainder = intendedOffering - wantedAmount;
            assert(msg.sender.send(remainder));
            Refund(msg.sender, remainder);
        }
        return true;
    }

}
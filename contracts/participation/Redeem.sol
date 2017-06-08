pragma solidity ^0.4.11;

import "./RedeemProtocol.sol";
import "../dependencies/DBC.sol";
import "../dependencies/Owned.sol";
import "../VaultProtocol.sol";


/// @title Redeem Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple and static Redeem Module.
contract Redeem is RedeemProtocol, DBC, Owned {

    // FIELDS

    // EVENTS

    // PRE, POST, INVARIANT CONDITIONS

    function isPastZero(uint x) internal returns (bool) { return 0 < x; }

    // CONSTANT METHODS

    // NON-CONSTANT METHODS

    function Redeem() {}

    /// Pre:  Redeemer has at least `numShares` shares
    /// Post: Redeemer lost `numShares`, and gained a slice of each asset (`coreAssetAmt * (numShares/totalShares)`)
    function redeemShares(address ofVault, uint numShares)
    {
        assert(numShares > 0);
        VaultProtocol Vault = VaultProtocol(ofVault);
        //uint sharesValue = Vault.calcValuePerShare(numShares);
        Vault.annihilateSharesOnBehalf(msg.sender, numShares);
    }

    /// Pre:  Redeemer has at least `numShares` shares
    /// Post: Redeemer lost `numShares`, and gained `numShares * value` reference tokens
    function redeemSharesForReferenceAsset(address ofVault, uint numShares) {}
}

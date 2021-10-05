// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

import "./org/clip.sol";

interface OracleLike {
    function read() external returns (bytes32);
}

interface BProtocolLike {
    function prepareBite(bytes32 ilk, uint256 amt, uint256 owe, uint256 med) external;
}


contract Blipper is Clipper {
    address public bprotocol;
    uint256 public bee; // b.protocol discount
    address public oracle;

    // --- Init ---
    constructor(address vat_, address spotter_, address dog_, bytes32 ilk_, address oracle_) public
        Clipper(vat_, spotter_, dog_, ilk_)
    {
        oracle = oracle_;
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) public override auth lock {
        if (what == "bee") {
            bee = data;
            File(what, data);
        }
        else {
            locked = 0;
            super.file(what, data);
        }
    }

    function file(bytes32 what, address data) public override auth lock {
        if (what == "bprotocol") {
            bprotocol = data;
            File(what, data);
        }
        else if(what == "oracle") {
            oracle = data;
            File(what, data);            
        }
        else {
            locked = 0;
            super.file(what, data);
        }
    }    


    // get the price directly from the OSM
    // Could get this from rmul(Vat.ilks(ilk).spot, Spotter.mat()) instead, but
    // if mat has changed since the last poke, the resulting value will be
    // incorrect.
    function getMedianPrice() internal returns (uint256 feedPrice) {
        feedPrice = uint256(OracleLike(oracle).read());
    }

    // --- Auction ---
    function blink(uint256 lot, uint256 tab, address usr, address kpr) public returns (uint256 amt, uint256 owe) {
        require(msg.sender == address(this), "Blipper/un-auth");

        // real time oracle price
        uint256 mid = getMedianPrice();

        // how much eth to get for the entire debt
        uint256 ask = rmul(tab, WAD) / rdiv(mid, bee);

        // how much dai to get for the entire collateral
        uint256 bid = mul(wmul(lot, rmul(mid, bee)), RAY);

        if(ask <= lot) {
            amt = ask;            
            owe = tab;
        }
        else {
            amt = lot;
            owe = bid;
            require(wmul(owe, dog.chop(ilk)) >= tab, "Blipper/low-ink");
        }

        BProtocolLike(bprotocol).prepareBite(ilk, amt, owe, mid);

        // execute the liquidation
        vat.move(bprotocol, vow, owe);
        vat.flux(ilk, address(this), bprotocol, amt);
        if(amt < lot) vat.flux(ilk, address(this), usr, lot - amt);

        // incentive to kick auction
        uint256 _tip  = tip;
        uint256 _chip = chip;
        uint256 coin;
        if (_tip > 0 || _chip > 0) {
            coin = add(_tip, wmul(tab, _chip));
            vat.suck(vow, kpr, coin);
        }

        // reset the Dirt
        dog.digs(ilk, tab);        
    }

    // dump on b.protocol or start an auction
    function kick(
        uint256 tab,  // Debt                   [rad]
        uint256 lot,  // Collateral             [wad]
        address usr,  // Address that will receive any leftover collateral
        address kpr   // Address that will receive incentives
    ) public auth lock isStopped(1) override returns (uint256 id) {
        try this.blink(lot, tab, usr, kpr) returns(uint256 /*amt*/, uint256 /*owe*/) {
            // TODO - emit events
        } catch {
            locked = 0;
            return super.kick(tab, lot, usr, kpr);
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

import "./org/clip.sol";

interface ExtPipLike {
    function src() external returns (address);
}

interface BProtocolLike {
    function prepareBite(bytes32 ilk, uint256 amt, uint256 owe, uint256 med) external;
}


contract Blipper is Clipper {
    address immutable public bprotocol;
    uint256 public bee; // b.protocol discount

    // --- Init ---
    constructor(address vat_, address spotter_, address dog_, bytes32 ilk_, address bprotocol_) public
        Clipper(vat_, spotter_, dog_, ilk_)
    {
        bprotocol = bprotocol_;
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) public override auth lock {
        if (what == "bee") {
            bee = data;
            File(what, data);
        }
        else super.file(what, data);
    }    


    // get the price directly from the OSM
    // Could get this from rmul(Vat.ilks(ilk).spot, Spotter.mat()) instead, but
    // if mat has changed since the last poke, the resulting value will be
    // incorrect.
    function getMedianPrice() internal returns (uint256 feedPrice) {
        (PipLike pip, ) = spotter.ilks(ilk);
        (bytes32 wut, bool ok) = PipLike(ExtPipLike(address(pip)).src()).peek();
        require(ok, "Blipper/invalid-price");

        uint256 val = uint256(wut);
        feedPrice = rdiv(mul(uint256(val), BLN), spotter.par());
    }

    // --- Auction ---
    function blink(uint256 lot, uint256 tab, address usr, address kpr) public returns (uint256 amt, uint256 owe) {
        require(msg.sender == address(this), "Blipper/un-auth");

        uint256 med = rmul(getMedianPrice(), bee);

        if(tab / med <= lot) {
            amt = tab / med;            
            owe = tab;
        }
        else {
            amt = lot;
            owe = mul(amt, med);
        }

        BProtocolLike(bprotocol).prepareBite(ilk, amt, owe, med);

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
            return super.kick(tab, lot, usr, kpr);
        }
    }
}

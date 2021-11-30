// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

interface VatLike {
    function move(address,address,uint256) external;
    function flux(bytes32,address,address,uint256) external;
    function ilks(bytes32) external returns (uint256, uint256, uint256, uint256, uint256);
    function suck(address,address,uint256) external;
}

interface DogLike {
    function chop(bytes32) external returns (uint256);
    function digs(bytes32, uint256) external;
}

interface OracleLike {
    function read() external returns (bytes32);
}

interface BProtocolLike {
    function prep(bytes32 ilk, uint256 amt, uint256 owe, uint256 mid) external;
}

interface ClipperLike {
    function dog() external view returns(DogLike);
    function vow() external view returns(address);
    function chip() external view returns(uint64);
    function tip() external view returns(uint192);
    function stopped() external view returns(uint256);

    function kick(
        uint256 tab,
        uint256 lot,
        address usr,
        address kpr
    ) external returns (uint256 id);
}


contract Blipper {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "Blipper/not-authorized");
        _;
    }

    // --- Clipper Data ---
    bytes32 immutable public ilk;   // Collateral type of this Clipper
    VatLike immutable public vat;   // Core CDP Engine
    DogLike public dog;   // Liquidation module
    address public vow;   // Recipient of dai raised in auctions
    uint64  public chip;  // Percentage of tab to suck from vow to incentivize keepers         [wad]
    uint192 public tip;   // Flat fee to suck from vow to incentivize keepers                  [rad]

    // --- B.Protocol Data ---
    address public clipper;
    address public bprotocol;
    uint256 public bee; // b.protocol discount
    address public oracle;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);

    event Blip(
        uint256 tab,
        uint256 lot,
        address usr,
        address kpr,
        uint256 amt,
        uint256 owe
    );
    
    // --- Init ---
    constructor(address vat_, bytes32 ilk_, address oracle_) public
    {        
        vat = VatLike(vat_);
        ilk = ilk_;
        oracle = oracle_;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);        
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "bee") bee = data;
        else revert("Blipper/file-unrecognized-param");

        emit File(what, data);        
    }

    function file(bytes32 what, address data) external auth {
        if (what == "bprotocol")    bprotocol = data;
        else if(what == "oracle")   oracle = data;
        else if(what == "clipper")  clipper = data;

        else revert("Blipper/file-unrecognized-param");

        emit File(what, data);        
    }    

    // --- Math ---
    uint256 constant BLN = 10 **  9;
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / WAD;
    }
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, RAY) / y;
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
        uint256 bid = rdiv(mul(wmul(lot, mid), RAY), bee);

        if(ask <= lot) {
            amt = ask;            
            owe = tab;
        }
        else {
            amt = lot;
            owe = bid;
            require(wmul(owe, dog.chop(ilk)) >= tab, "Blipper/low-ink");
        }

        BProtocolLike(bprotocol).prep(ilk, amt, owe, mid);

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
    ) public auth returns (uint256 id) {
        require(ClipperLike(clipper).stopped() < 1, "Blipper/stopped-incorrect");

        try this.blink(lot, tab, usr, kpr) returns(uint256 amt, uint256 owe) {
            emit Blip(tab, lot, usr, kpr, amt, owe);
            return 0;
        } catch {
            return ClipperLike(clipper).kick(tab, lot, usr, kpr);
        }
    }

    // Public function to update the cached clipper params.
    function upparams() public {
        dog = ClipperLike(clipper).dog();
        vow = ClipperLike(clipper).vow();
        chip = ClipperLike(clipper).chip();
        tip = ClipperLike(clipper).tip();
    }    
}

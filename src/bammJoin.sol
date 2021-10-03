// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

import "./PriceFormula.sol";
import { DSAuth } from "ds-auth/auth.sol";
import { DSToken } from "ds-token/token.sol";

interface PipLike {
    function peek() external view returns(bytes32 val, bool has);
}

interface SpotterLike {
    function par() external view returns (uint256);
    function ilks(bytes32) external view returns (address, uint256);
}

interface PotLike {
    function drip() external returns (uint tmp);
    function join(uint wad) external;
    function exit(uint wad) external;
    function pie(address) external view returns(uint);
    function chi() external view returns(uint);    
}

interface VatLike {
    function hope(address) external;
    function flux(bytes32, address, address, uint) external;
    function move(address, address, uint) external;
    function dai(address) external view returns(uint);
    function gem(bytes32, address) external view returns(uint);
}


contract BAMMJoin is PriceFormula, DSAuth, DSToken {
    VatLike public immutable vat;
    SpotterLike public immutable spotter;
    bytes32 public immutable ilk;
    address public immutable blipper;
    PotLike public immutable pot;


    address public immutable feePool;
    uint public constant MAX_FEE = 100; // 1%
    uint public fee = 0; // fee in bps
    uint public A = 20;
    uint public constant MIN_A = 20;
    uint public constant MAX_A = 200;    

    uint public immutable maxDiscount; // max discount in bips

    uint constant public PRECISION = 1e18;

    event ParamsSet(uint A, uint fee);
    event UserDeposit(address indexed user, uint wad, uint numShares);
    event UserWithdraw(address indexed user, uint wad, uint gem, uint numShares);
    event RebalanceSwap(address indexed user, uint wad, uint gem, uint timestamp);

    constructor(
        address _vat,
        address _spotter,
        bytes32 _ilk,
        address _blipper,
        address _pot,
        address _feePool,
        uint    _maxDiscount)
        public
        DSToken("BMB") // TODO better name for token
    {
        vat = VatLike(_vat);
        spotter = SpotterLike(_spotter);
        ilk = _ilk;
        blipper = _blipper;
        pot = PotLike(_pot);

        feePool = _feePool;
        maxDiscount = _maxDiscount;
    }

    function setParams(uint _A, uint _fee) external auth {
        require(_fee <= MAX_FEE, "setParams: fee is too big");
        require(_A >= MIN_A, "setParams: A too small");
        require(_A <= MAX_A, "setParams: A too big");

        fee = _fee;
        A = _A;

        emit ParamsSet(_A, _fee);
    }

    function fetchPrice() public view returns(uint) {
        (address pip, ) = spotter.ilks(ilk);
        (bytes32 val, bool has) = PipLike(pip).peek();
        require(has, "bammJoin/invalid-price");
        uint BLN = 10 **  9;
        return rdiv(mul(uint256(val), BLN), spotter.par());

        // TODO - sanity check with OSM?
    }

    function deposit(uint wad) external {        
        // update share
        uint usdValue = pot.pie(address(this));
        uint gemValue = vat.gem(ilk, address(this));

        uint price = fetchPrice();
        require(gemValue == 0 || price > 0, "deposit: feed is down");

        uint totalValue = usdValue.add(gemValue.mul(price));

        // this is in theory not reachable. if it is, better halt deposits
        // the condition is equivalent to: (totalValue = 0) ==> (total = 0)
        require(totalValue > 0 || totalSupply == 0, "deposit: system is rekt");

        uint newShare = PRECISION;
        if(totalSupply > 0) newShare = totalValue.mul(mul(wad, RAY)) / totalSupply;

        totalSupply = totalSupply.add(newShare);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(newShare);

        pot.drip();

        uint chi = pot.chi();
        uint rad = mul(chi, wad);
        vat.move(msg.sender, address(this), rad);
        pot.join(wad);

        emit Transfer(address(0), msg.sender, newShare);
        emit UserDeposit(msg.sender, wad, newShare);        
    }

    function withdraw(uint numShares) external {
        require(balanceOf[msg.sender] >= numShares, "withdraw: insufficient balance");

        uint usdValue = pot.pie(address(this));
        uint gemValue = vat.gem(ilk, address(this));

        uint usdAmount = usdValue.mul(numShares).div(totalSupply);
        uint gemAmount = gemValue.mul(numShares).div(totalSupply);

        uint chi = pot.chi();
        uint rad = usdAmount.mul(chi);

        pot.exit(usdAmount);
        vat.move(address(this), msg.sender, rad);

        if(gemAmount > 0) {
            vat.flux(ilk, address(this), msg.sender, gemAmount);
        }

        balanceOf[msg.sender] = balanceOf[msg.sender].sub(numShares);
        totalSupply = totalSupply.sub(numShares);

        emit Transfer(msg.sender, address(0), numShares);
        emit UserWithdraw(msg.sender, usdAmount, gemAmount, numShares);            
    }

    function addBps(uint n, int bps) internal pure returns(uint) {
        require(bps <= 10000, "reduceBps: bps exceeds max");
        require(bps >= -10000, "reduceBps: bps exceeds min");

        return n.mul(uint(10000 + bps)) / 10000;
    }

    function getSwapGemAmount(uint wad) public view returns(uint gemAmount, uint feeGemAmount) {
        uint usdBalance = pot.pie(address(this));
        uint gemBalance = vat.gem(ilk, address(this));

        uint gem2usdPrice = fetchPrice();
        if(gem2usdPrice == 0) return (0, 0); // feed is down

        uint gemUsdValue = gemBalance.mul(gem2usdPrice) / PRECISION;
        uint maxReturn = addBps(wad.mul(PRECISION) / gem2usdPrice, int(maxDiscount));

        uint xQty = wad;
        uint xBalance = usdBalance;
        uint yBalance = usdBalance.add(gemUsdValue.mul(2));
        
        uint usdReturn = getReturn(xQty, xBalance, yBalance, A);
        uint basicGemReturn = usdReturn.mul(PRECISION) / gem2usdPrice;

        if(gemBalance < basicGemReturn) basicGemReturn = gemBalance; // cannot give more than balance 
        if(maxReturn < basicGemReturn) basicGemReturn = maxReturn;

        gemAmount = addBps(basicGemReturn, -int(fee));
        feeGemAmount = basicGemReturn.sub(gemAmount); // TODO - revise fees
    }

    // get gem in return to LUSD
    function swap(uint wad, uint minGemReturn, address dest) public returns(uint) {
        (uint gemAmount, uint feeGemAmount) = getSwapGemAmount(wad);

        require(gemAmount >= minGemReturn, "swap: low return");

        vat.move(msg.sender, address(this), mul(wad, RAY));
        pot.join(wad);

        if(feeGemAmount > 0) vat.flux(ilk, address(this), feePool, feeGemAmount);
        vat.flux(ilk, address(this), dest, gemAmount);

        emit RebalanceSwap(msg.sender, wad, gemAmount, now);

        return gemAmount;
    }

    function prepareBite(bytes32 /*ilk*/, uint256 /*amt*/, uint256 owe, uint256 /*med*/) external {
        // TODO - sanity checks on the price
        require(msg.sender == blipper, "prepareBite: !auth");
        uint chi = pot.chi();
        uint wad = (owe / chi).add(1);
        pot.exit(wad);
    }

    function pottify() external {
        uint chi = pot.chi();
        uint rad = vat.dai(address(this));
        pot.drip();
        pot.join(rad / chi);
    }
}
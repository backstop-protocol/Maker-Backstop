// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

import "./PriceFormula.sol";
import { DSAuth } from "ds-auth/auth.sol";
import { DSToken } from "ds-token/token.sol";

interface OracleLike {
    function read() external view returns (bytes32);
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
    OracleLike public immutable oracle;
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
        address _oracle,
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
        oracle = OracleLike(_oracle);
        ilk = _ilk;
        blipper = _blipper;
        pot = PotLike(_pot);

        feePool = _feePool;
        maxDiscount = _maxDiscount;

        VatLike(_vat).hope(_pot);
        VatLike(_vat).hope(_blipper);
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
        return uint(oracle.read());
        // TODO - sanity check with OSM?
    }

    function deposit(uint wad) external {
        pot.drip();
        uint chi = pot.chi();

        // update share
        uint usdValue = rmul(pot.pie(address(this)), chi);
        uint gemValue = vat.gem(ilk, address(this));

        uint price = fetchPrice();
        require(gemValue == 0 || price > 0, "deposit: feed is down");

        uint totalValue = usdValue.add(gemValue.mul(price) / WAD);

        // this is in theory not reachable. if it is, better halt deposits
        // the condition is equivalent to: (totalValue = 0) ==> (total = 0)
        require(totalValue > 0 || totalSupply == 0, "deposit: system is rekt");

        uint newShare = WAD;
        if(totalSupply > 0) newShare = wad.mul(totalSupply) / totalValue;

        totalSupply = totalSupply.add(newShare);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(newShare);

        vat.move(msg.sender, address(this), mul(RAY, wad));
        pot.join(rdiv(wad, chi).sub(1)); // avoid rounding errors

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

    function getSwapGemAmount(uint wad) public view returns(uint gemAmount, uint chi) {
        chi = pot.chi();
        uint usdBalance = rmul(pot.pie(address(this)), chi);
        uint gemBalance = vat.gem(ilk, address(this));

        uint gem2usdPrice = fetchPrice();
        if(gem2usdPrice == 0) return (0, chi); // feed is down

        uint gemUsdValue = gemBalance.mul(gem2usdPrice) / PRECISION;
        uint maxReturn = addBps(wad.mul(PRECISION) / gem2usdPrice, int(maxDiscount));

        uint xQty = wad;
        uint xBalance = usdBalance;
        uint yBalance = usdBalance.add(gemUsdValue.mul(2));
        
        uint usdReturn = getReturn(xQty, xBalance, yBalance, A);
        uint basicGemReturn = usdReturn.mul(PRECISION) / gem2usdPrice;

        if(gemBalance < basicGemReturn) basicGemReturn = gemBalance; // cannot give more than balance 
        if(maxReturn < basicGemReturn) basicGemReturn = maxReturn;

        gemAmount = basicGemReturn;
    }

    // get gem in return to LUSD
    function swap(uint wad, uint minGemReturn, address dest) public returns(uint) {
        (uint gemAmount, uint chi) = getSwapGemAmount(wad);

        require(gemAmount >= minGemReturn, "swap: low return");

        vat.move(msg.sender, address(this), mul(wad, RAY));

        uint feeWad = (addBps(wad, int(fee))).sub(wad);
        if(feeWad > 0) vat.move(address(this), feePool, feeWad * RAY);

        uint depositAmount = rdiv(wad.sub(feeWad), chi);
        pot.join(depositAmount.sub(1)); // avoid rounding errors reverts

        vat.flux(ilk, address(this), dest, gemAmount);

        emit RebalanceSwap(msg.sender, wad, gemAmount, now);

        return gemAmount;
    }

    function prep(bytes32 /*ilk*/, uint256 /*amt*/, uint256 owe, uint256 /*med*/) external {
        // TODO - sanity checks on the price
        require(msg.sender == blipper, "prep: !auth");
        uint chi = pot.chi();
        uint wad = (owe / chi).add(1);
        pot.exit(wad);
    }

    function pottify() external {
        pot.drip();        
        uint chi = pot.chi();
        uint rad = vat.dai(address(this));
        pot.join(rad / chi);
    }
}
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

interface CTokenLike {
    function mint(uint mintAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function balanceOfUnderlying(address account) external view returns (uint);
}

interface GemLike {
    function approve(address, uint256) external returns(bool);
    function transfer(address, uint256) external returns(bool);
    function transferFrom(address, address, uint256) external returns(bool);
    function balanceOf(address) view external returns(uint);
}

interface DaiJoinLike {
    function join(address usr, uint wad) external;
    function exit(address usr, uint wad) external;
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
    CTokenLike public immutable cDai;
    GemLike public immutable dai;
    DaiJoinLike public immutable daiJoin;


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
        address _dai,
        address _daiJoin,
        address _cDai,
        address _feePool,
        uint    _maxDiscount,
        address _autoCompounder,
        address _crop)
        public
        DSToken("BMB") // TODO better name for token
    {
        vat = VatLike(_vat);
        spotter = SpotterLike(_spotter);
        oracle = OracleLike(_oracle);
        ilk = _ilk;
        blipper = _blipper;

        dai = GemLike(_dai);
        daiJoin = DaiJoinLike(_daiJoin);
        cDai = CTokenLike(_cDai);

        feePool = _feePool;
        maxDiscount = _maxDiscount;

        require(GemLike(_dai).approve(_cDai, uint(-1)), "constructor/dai-allowance-failed");
        require(GemLike(_dai).approve(_daiJoin, uint(-1)), "constructor/dai-allowance-failed");        
        VatLike(_vat).hope(_blipper);
        VatLike(_vat).hope(_daiJoin);        
        require(GemLike(_crop).approve(_autoCompounder, uint(-1)), "constructor/dai-allowance-failed");
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
        // update share
        uint usdValue = cDai.balanceOfUnderlying(address(this));
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

        // deposit the wad
        require(dai.transferFrom(msg.sender, address(this), wad), "deposit/transferFrom-failed");
        require(cDai.mint(wad) == 0, "deposit/cToken-mint-failed");

        emit Transfer(address(0), msg.sender, newShare);
        emit UserDeposit(msg.sender, wad, newShare);        
    }

    function withdraw(uint numShares) external {
        require(balanceOf[msg.sender] >= numShares, "withdraw: insufficient balance");

        uint usdValue = cDai.balanceOfUnderlying(address(this));
        uint gemValue = vat.gem(ilk, address(this));

        uint usdAmount = usdValue.mul(numShares).div(totalSupply);
        uint gemAmount = gemValue.mul(numShares).div(totalSupply);

        // todo - can this withdraw less than usdAmount due to rounding errors?
        require(cDai.redeemUnderlying(usdAmount) == 0, "withdraw/redeemUnderlying-failed");
        require(dai.transfer(msg.sender, usdAmount), "withdraw/transfer-failed");

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

    function getSwapGemAmount(uint wad) public view returns(uint gemAmount) {
        uint usdBalance = cDai.balanceOfUnderlying(address(this));
        uint gemBalance = vat.gem(ilk, address(this));

        uint gem2usdPrice = fetchPrice();
        if(gem2usdPrice == 0) return (0); // feed is down

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
        uint gemAmount = getSwapGemAmount(wad);

        require(gemAmount >= minGemReturn, "swap: low return");

        require(dai.transferFrom(msg.sender, address(this), wad), "swap/transferFrom-failed");

        uint feeWad = (addBps(wad, int(fee))).sub(wad);
        if(feeWad > 0) require(dai.transfer(feePool, feeWad), "swap/transfer-failed");

        uint depositAmount = wad.sub(feeWad);
        require(cDai.mint(depositAmount) == 0, "swap/ctoken-mint-failed");

        vat.flux(ilk, address(this), dest, gemAmount);

        emit RebalanceSwap(msg.sender, wad, gemAmount, now);

        return gemAmount;
    }

    function prep(bytes32 /*ilk*/, uint256 /*amt*/, uint256 owe, uint256 /*med*/) external {
        // TODO - sanity checks on the price
        require(msg.sender == blipper, "prep: !auth");
        uint wad = (owe / RAY).add(1); // avoid rounding errors
        require(cDai.redeemUnderlying(wad) == 0, "prep/redeemUnderlying-failed");
        daiJoin.join(address(this), wad);
    }

    // callable by anyone
    function crop() external {
        // this is just in case some dai got stuck in the vat
        daiJoin.exit(address(this), vat.dai(address(this)) / RAY);
        require(cDai.mint(dai.balanceOf(address(this))) == 0, "prottify/ctoken-mint-failed");
    }
}
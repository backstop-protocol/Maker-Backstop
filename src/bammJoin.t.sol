pragma solidity >=0.6.12;

import { DssDeployTestBase, Vat, Dai } from "dss-deploy/DssDeploy.t.base.sol";
import { Blipper } from "./blip.sol";
import { BAMMJoin } from "./bammJoin.sol";
import { CToken } from "./mock/ctoken.sol";
import { DSToken } from "ds-token/token.sol";

contract FakeUser {
    function doHope(Dai dai, BAMMJoin bamm) public {
        dai.approve(address(bamm), uint(-1));
    }

    function doDeposit(BAMMJoin bamm, uint wad) public {
        bamm.deposit(wad);
    }

    function doWithdraw(BAMMJoin bamm, uint amt) public {
        bamm.withdraw(amt);
    }

    function doDumpDai(Dai dai) public {
        dai.transfer(address(0xdeadbeef), dai.balanceOf(address(this)));
    }
}

contract BammJoinTest is DssDeployTestBase {
    BAMMJoin bamm;
    CToken cDai;

    FakeUser u1;
    FakeUser u2;
    FakeUser u3;

    function setUp() override public {

        super.setUp();
        deploy();
        
        u1 = new FakeUser();
        u2 = new FakeUser();
        u3 = new FakeUser();

        cDai = new CToken(address(dai));

        bamm = new BAMMJoin(address(vat),
                            address(spotter),
                            address(pipETH),
                            "ETH",
                            address(0xb1),
                            address(dai),
                            address(daiJoin),
                            address(cDai),
                            address(0xfee),
                            400,
                            address(0xc),
                            address(new DSToken("comp")));

        this.rely(address(vat), address(this));
        vat.suck(address(0x5), address(this), 1000000000 ether * RAY);
        vat.slip("ETH", address(this), 100000000 ether);
        vat.hope(address(daiJoin));

        daiJoin.exit(address(u1), 1000000 ether);
        daiJoin.exit(address(u2), 1000000 ether);
        daiJoin.exit(address(u3), 1000000 ether);

        daiJoin.exit(address(this), 1000000 ether);

        u1.doHope(dai, bamm);
        u2.doHope(dai, bamm);
        u3.doHope(dai, bamm);

        dai.approve(address(bamm), uint(-1));
    }

    function testDepositWithdrawWithoutGem() public {
        uint vatBalBefore = dai.balanceOf(address(u1));

        // deposit
        u1.doDeposit(bamm, 1 ether);
        u2.doDeposit(bamm, 2 ether);
        u3.doDeposit(bamm, 3 ether);                

        uint b1 = bamm.balanceOf(address(u1));
        uint b2 = bamm.balanceOf(address(u2));
        uint b3 = bamm.balanceOf(address(u3));

        // check that token balance are good
        assertEq(b1 * 2, b2, "unexpected b2 after deposit");
        assertEq(b1 * 3, b3, "unexpected b3 after deposit");

        assertEq(bamm.totalSupply(), (1 + 2 + 3) * WAD, "unexpected total supply after deposit");

        // check that expected amount of dai was taken
        assertEq(vatBalBefore, dai.balanceOf(address(u1)) + 1 ether, "u1 vat.dai");
        assertEq(vatBalBefore, dai.balanceOf(address(u2)) + 2 ether, "u2 vat.dai");
        assertEq(vatBalBefore, dai.balanceOf(address(u3)) + 3 ether, "u3 vat.dai");

        // check that all dai went to cDai
        assertEq(dai.balanceOf(address(cDai)), 6 ether, "unexpected dai in cDai");

        // do partial withdraw
        u1.doWithdraw(bamm, b1 / 2);
        u2.doWithdraw(bamm, b2 / 2);
        u3.doWithdraw(bamm, b3 / 2);        

        b1 = bamm.balanceOf(address(u1));
        b2 = bamm.balanceOf(address(u2));
        b3 = bamm.balanceOf(address(u3));

        // check that token balance are good
        assertEq(b1 * 2, b2, "unexpected b2 after withdraw");
        assertEq(b1 * 3, b3, "unexpected b3 after withdraw");

        assertEq(bamm.totalSupply(), (1 + 2 + 3) * WAD / 2, "unexpected total supply after withdraw");        

        // check that expected amount of dai was withdrawn
        assertEq(vatBalBefore, dai.balanceOf(address(u1)) + 0.5 ether, "u1 vat.dai after withdraw");
        assertEq(vatBalBefore, dai.balanceOf(address(u2)) + 1 ether, "u2 vat.dai after withdraw");
        assertEq(vatBalBefore, dai.balanceOf(address(u3)) + 1.5 ether, "u3 vat.dai after withdraw");

        // check that expected dai amount withdrawn from pot
        assertEq(dai.balanceOf(address(cDai)), 3 ether, "unexpected dai in pot");        
    }

    function testDepositWithdrawWithGem() public {
        bamm.deposit(10 ether);
        vat.flux("ETH", address(this), address(bamm), 1 ether);
        pipETH.poke(bytes32(uint(10 * 1e18)));

        // at this point the pool net worth is 20 dai, and token balance is 1 WAD

        u1.doDeposit(bamm, 2 ether);
        assertEq(bamm.balanceOf(address(u1)), 0.1 ether, "unexpected bamm bal");

        u1.doDumpDai(dai);

        // the pool now have 12 dai and 10 eth
        // withdraw half - should get 1 dai net worth, where 12/22 of them in dai, and 10/22 in eth.
        u1.doWithdraw(bamm, 0.05 ether);
        assertEq(dai.balanceOf(address(u1)), WAD * 12 / 22, "unexpected dai balance");
        assertEq(vat.gem("ETH", address(u1)), WAD * 1 / 22, "unexpected gem balance"); // 1 eth = 10 dai

        assertEq(bamm.balanceOf(address(u1)), 0.05 ether, "unexpected bamm bal after withdraw");

        // check that expected dai amount withdrawn from pot
        assertEq(dai.balanceOf(address(cDai)), 12 ether - WAD * 12 / 22, "unexpected dai in pot");
    }

    function assertEqualPlusMinus1(uint a, uint b, string memory err) internal {
        if(a > b + 1) assertEq(a, b, err);
        if(b > a + 1) assertEq(a, b, err);
    }

    function testPriceFormulaFuzzy() public {
        uint A = 3;
        uint aStep = 7;
        uint xQty  = 1234567891;
        uint xBalance = 321851652450;
        uint yBalance = 219413622039;

        // this was generated by a python script in used in the production code here https://github.com/backstop-protocol/dev/blob/main/packages/contracts/test/B.Protocol/PriceFormulaTest.js
        uint[100] memory excpectedResult = [uint(1188895769), 2411018031, 3638812385, 4868601476, 6099325960, 7330566424, 8562123398, 9793889769, 11025802785, 12257823179, 13489925074, 14722090684, 15954307349, 17186565794, 18418859045, 19651181742, 20883529689, 22115899540, 23348288590, 24580694617, 25813115778, 27045550524, 28277997542, 29510455706, 30742924044, 31975401710, 33207887963, 34440382148, 35672883685, 36905392053, 38137906789, 39370427472, 40602953723, 41835485196, 43068021577, 44300562576, 45533107928, 46765657391, 47998210737, 49230767758, 50463328261, 51695892065, 52928459002, 54161028915, 55393601657, 56626177090, 57858755085, 59091335520, 60323918281, 61556503261, 62789090357, 64021679473, 65254270518, 66486863407, 67719458057, 68952054392, 70184652337, 71417251823, 72649852784, 73882455156, 75115058879, 76347663896, 77580270153, 78812877597, 80045486178, 81278095850, 82510706566, 83743318283, 84975930960, 86208544556, 87441159035, 88673774360, 89906390495, 91139007408, 92371625066, 93604243438, 94836862496, 96069482210, 97302102554, 98534723502, 99767345029, 100999967109, 102232589722, 103465212843, 104697836453, 105930460530, 107163085054, 108395710007, 109628335370, 110860961126, 112093587257, 113326213748, 114558840582, 115791467745, 117024095222, 118256722999, 119489351063, 120721979399, 121954607997, 123187236843];

        for(uint i = 0 ; i < 100 ; i++) {
            uint newA = A + aStep*(i+1);
            uint qty = xQty * (i+1);

            uint xbalance = xBalance + qty * 3;
            uint ybalance = yBalance + qty;

            uint ret = bamm.getReturn(qty, xbalance, ybalance, newA);
            assertEqualPlusMinus1(ret, excpectedResult[i], "unexpected price");
        }
    }

    function testGetSwapAmountExceedsDiscount() public {
        // price = 105
        // dai deposit = 6000e18
        // A = 20
        // gem = 39799999999999999975
        // qty wad = 105e16
        // expected gem return = 104e16

        bamm.setParams(20, 0);
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 100e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint retGem = bamm.getSwapGemAmount(105e18);
        assertEq(retGem, 104e16, "unexpected retGem");
    }

    function testGetSwapAmountHappy() public {
        // price = 105
        // dai deposit = 6000e18
        // A = 20
        // qty wad = 105e16
        // expected gem return = 104e16

        bamm.setParams(20, 0);
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 2e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint qty = 105e18;
        uint xbalance = 6000e18;
        uint ybalance = 2e18 * 105 * 2 + xbalance;
        uint expectedRet = (bamm.getReturn(qty, xbalance, ybalance, 20)) / 105;

        uint retGem = bamm.getSwapGemAmount(qty);
        assertEq(retGem, expectedRet, "unexpected retGem");
    }

    function testGetSwapAmountExceedBalance() public {
        bamm.setParams(20, 0);
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 1e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint retGem = bamm.getSwapGemAmount(1000e18);
        assertEq(retGem, 1e18, "unexpected retGem");
    }

    // swap tests - without fee. with fee. and revert on low return
    function testSwapNoFee() public {
        bamm.setParams(20, 0);
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 2e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint qty = 105e18;
        uint retGem = bamm.getSwapGemAmount(qty);        

        uint daiBefore = dai.balanceOf(address(this));
        uint potBefore = dai.balanceOf(address(cDai));

        bamm.swap(qty, 1, address(0xddd));

        uint daiAfter = dai.balanceOf(address(this));
        uint potAfter = dai.balanceOf(address(cDai));        
        uint gem = vat.gem("ETH", address(0xddd));

        assertEq(daiBefore - daiAfter, qty, "unexpected this dai balance");
        assertEq(potAfter - potBefore, qty, "unexpected this pot balance");        
        assertEq(gem, retGem, "unexpected gem balance");
    }

    function testSwapWithFee() public {
        bamm.setParams(20, 100); // 1% fee
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 2e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint qty = 105e18;
        uint retGem = bamm.getSwapGemAmount(qty);        

        uint daiBefore = dai.balanceOf(address(this));
        uint potBefore = dai.balanceOf(address(cDai));

        bamm.swap(qty, 1, address(0xddd));

        uint daiAfter = dai.balanceOf(address(this));
        uint potAfter = dai.balanceOf(address(cDai));        
        uint gem = vat.gem("ETH", address(0xddd));

        assertEq(daiBefore - daiAfter, qty, "unexpected this dai balance");
        // account for fees
        assertEq(potAfter - potBefore, qty * 99 / 100, "unexpected this pot balance");
        assertEq(dai.balanceOf(address(0xfee)), qty / 100, "unexpected fee balance");
        assertEq(gem, retGem, "unexpected gem balance");
    }

    function testFailSwapLowReturn() public {
        bamm.setParams(20, 100); // 1% fee
        bamm.deposit(6000e18);
        vat.flux("ETH", address(this), address(bamm), 2e18);
        pipETH.poke(bytes32(uint(105e18)));

        uint qty = 105e18;

        bamm.swap(qty, qty * 106, address(0xddd));
    }
}


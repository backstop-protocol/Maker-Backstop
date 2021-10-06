pragma solidity >=0.6.12;

import { DssDeployTestBase, Vat } from "dss-deploy/DssDeploy.t.base.sol";
import { Blipper } from "./blip.sol";
import { BAMMJoin } from "./bammJoin.sol";

contract FakeUser {
    function doHope(Vat vat, BAMMJoin bamm) public {
        vat.hope(address(bamm));
    }

    function doDeposit(BAMMJoin bamm, uint wad) public {
        bamm.deposit(wad);
    }

    function doWithdraw(BAMMJoin bamm, uint amt) public {
        bamm.withdraw(amt);
    }

    function doDumpDai(Vat vat) public {
        vat.move(address(this), address(0xdeadbeef), vat.dai(address(this)));
    }
}

contract BammJoinTest is DssDeployTestBase {
    BAMMJoin bamm;
    FakeUser u1;
    FakeUser u2;
    FakeUser u3;

    function setUp() override public {

        super.setUp();
        deploy();
        
        u1 = new FakeUser();
        u2 = new FakeUser();
        u3 = new FakeUser();

        bamm = new BAMMJoin(address(vat), address(spotter), address(pipETH), "ETH", address(0xb1), address(pot), address(0xfee), 400);

        this.rely(address(vat), address(this));
        vat.suck(address(0x5), address(this), 1000000000 ether * RAY);
        vat.slip("ETH", address(this), 100000000 ether);

        // set chi to non 1 value
        this.rely(address(pot), address(this));
        pot.file("dsr", 11e26);
        hevm.warp(now+2);
        pot.drip();
        pot.file("dsr", 0);
        require(pot.chi() > 1, "chi is 1");

        vat.move(address(this), address(u1), 1000000 ether * RAY);
        vat.move(address(this), address(u2), 1000000 ether * RAY);
        vat.move(address(this), address(u3), 1000000 ether * RAY);

        u1.doHope(vat, bamm);
        u2.doHope(vat, bamm);
        u3.doHope(vat, bamm);
    }

    function assertEqualApproxWad(uint a, uint b, string memory err) internal {
        if(a > b + 10) assertEq(a, b, err);
        if(b > a + 10) assertEq(a, b, err);
    }

    function assertEqualApproxRad(uint a, uint b, string memory err) internal {
        assertEqualApproxWad(a / RAY, b / RAY, err);

    }    

    function testDepositWithdrawWithoutGem() public {
        uint vatBalBefore = vat.dai(address(u1));

        // deposit
        u1.doDeposit(bamm, 1 ether);
        u2.doDeposit(bamm, 2 ether);
        u3.doDeposit(bamm, 3 ether);                

        uint b1 = bamm.balanceOf(address(u1));
        uint b2 = bamm.balanceOf(address(u2));
        uint b3 = bamm.balanceOf(address(u3));

        // check that token balance are good
        assertEqualApproxWad(b1 * 2, b2, "unexpected b2 after deposit");
        assertEqualApproxWad(b1 * 3, b3, "unexpected b3 after deposit");

        assertEqualApproxWad(bamm.totalSupply(), (1 + 2 + 3) * WAD, "unexpected total supply after deposit");

        // check that expected amount of dai was taken
        assertEq(vatBalBefore, vat.dai(address(u1)) + 1 ether * RAY, "u1 vat.dai");
        assertEq(vatBalBefore, vat.dai(address(u2)) + 2 ether * RAY, "u2 vat.dai");
        assertEq(vatBalBefore, vat.dai(address(u3)) + 3 ether * RAY, "u3 vat.dai");

        // check that all dai went to pot
        assertEqualApproxRad(vat.dai(address(pot)), 6 ether * RAY, "unexpected dai in pot");

        // do partial withdraw
        u1.doWithdraw(bamm, b1 / 2);
        u2.doWithdraw(bamm, b2 / 2);
        u3.doWithdraw(bamm, b3 / 2);        

        b1 = bamm.balanceOf(address(u1));
        b2 = bamm.balanceOf(address(u2));
        b3 = bamm.balanceOf(address(u3));

        // check that token balance are good
        assertEqualApproxWad(b1 * 2, b2, "unexpected b2 after withdraw");
        assertEqualApproxWad(b1 * 3, b3, "unexpected b3 after withdraw");

        assertEqualApproxWad(bamm.totalSupply(), (1 + 2 + 3) * WAD / 2, "unexpected total supply after withdraw");        

        // check that expected amount of dai was withdrawn
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u1)) + 0.5 ether * RAY, "u1 vat.dai after withdraw");
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u2)) + 1 ether * RAY, "u2 vat.dai after withdraw");
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u3)) + 1.5 ether * RAY, "u3 vat.dai after withdraw");

        // check that expected dai amount withdrawn from pot
        assertEqualApproxRad(vat.dai(address(pot)), 3 ether * RAY, "unexpected dai in pot");        
    }

    function testDepositWithdrawWithGem() public {
        vat.hope(address(bamm));
        bamm.deposit(10 ether);
        vat.flux("ETH", address(this), address(bamm), 1 ether);
        pipETH.poke(bytes32(uint(10 * 1e18)));

        // at this point the pool net worth is 20 dai, and token balance is 1 WAD

        u1.doDeposit(bamm, 2 ether);
        assertEqualApproxWad(bamm.balanceOf(address(u1)), 0.1 ether, "unexpected bamm bal");

        u1.doDumpDai(vat);

        // the pool now have 12 dai and 10 eth
        // withdraw half - should get 1 dai net worth, where 12/22 of them in dai, and 10/22 in eth.
        u1.doWithdraw(bamm, 0.05 ether);
        assertEqualApproxRad(vat.dai(address(u1)), RAY * WAD * 12 / 22, "unexpected dai balance");
        assertEqualApproxWad(vat.gem("ETH", address(u1)), WAD * 1 / 22, "unexpected gem balance"); // 1 eth = 10 dai

        assertEqualApproxWad(bamm.balanceOf(address(u1)), 0.05 ether, "unexpected bamm bal after withdraw");

        // check that expected dai amount withdrawn from pot
        assertEqualApproxRad(vat.dai(address(pot)), 12 ether * RAY - RAY * WAD * 12 / 22, "unexpected dai in pot");
    }    
}


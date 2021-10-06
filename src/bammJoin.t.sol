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
}

interface Hevm {
    function warp(uint256) external;
}

contract BammJoinTest is DssDeployTestBase {
    BAMMJoin bamm;
    FakeUser u1;
    FakeUser u2;
    FakeUser u3;

    Hevm hevm2;

    function setUp() override public {

        super.setUp();
        deploy();
        
        u1 = new FakeUser();
        u2 = new FakeUser();
        u3 = new FakeUser();

        bamm = new BAMMJoin(address(vat), address(spotter), "ETH", address(0xb1), address(pot), address(0xfee), 400);

        this.rely(address(vat), address(this));
        vat.suck(address(0x5), address(this), 100000000 ether * 1e27);
        vat.slip("ETH", address(this), 100000000 ether);

        // set chi to non 1 value
        this.rely(address(pot), address(this));
        pot.file("dsr", 11e26);
        hevm.warp(now+2);
        pot.drip();
        pot.file("dsr", 0);
        require(pot.chi() > 1, "chi is 1");

        vat.move(address(this), address(u1), 1000000 ether * 1e27);
        vat.move(address(this), address(u2), 1000000 ether * 1e27);
        vat.move(address(this), address(u3), 1000000 ether * 1e27);

        u1.doHope(vat, bamm);
        u2.doHope(vat, bamm);
        u3.doHope(vat, bamm);
    }

    function assertEqualApproxWad(uint a, uint b, string memory err) internal {
        if(a > b + 1) assertEq(a, b, err);
        if(b > a + 1) assertEq(a, b, err);
    }

    function assertEqualApproxRad(uint a, uint b, string memory err) internal {
        assertEqualApproxWad(a / 1e27, b / 1e27, err);

    }    

    function testDepositWithoutGem() public {
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

        // check that expected amount of dai was taken
        assertEq(vatBalBefore, vat.dai(address(u1)) + 1 ether * 1e27, "u1 vat.dai");
        assertEq(vatBalBefore, vat.dai(address(u2)) + 2 ether * 1e27, "u2 vat.dai");
        assertEq(vatBalBefore, vat.dai(address(u3)) + 3 ether * 1e27, "u3 vat.dai");

        // check that all dai went to pot
        assertEqualApproxRad(vat.dai(address(pot)), 6 ether * 1e27, "unexpected dai in pot");

        // do partial withdraw
        u1.doWithdraw(bamm, b1 / 2);
        u2.doWithdraw(bamm, b2 / 2);
        u3.doWithdraw(bamm, b3 / 2);        

        b1 = bamm.balanceOf(address(u1));
        b2 = bamm.balanceOf(address(u2));
        b3 = bamm.balanceOf(address(u3));

        // check that token balance are good
        assertEqualApproxWad(b1 * 2, b2, "unexpected b2 after deposit");
        assertEqualApproxWad(b1 * 3, b3, "unexpected b3 after deposit");

        // check that expected amount of dai was withdrawn
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u1)) + 0.5 ether * 1e27, "u1 vat.dai after withdraw");
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u2)) + 1 ether * 1e27, "u2 vat.dai after withdraw");
        assertEqualApproxRad(vatBalBefore, vat.dai(address(u3)) + 1.5 ether * 1e27, "u3 vat.dai after withdraw");

        // check that expected dai amount withdrawn from pot
        assertEqualApproxRad(vat.dai(address(pot)), 3 ether * 1e27, "unexpected dai in pot");        
    }
}

//82.7838828 eth for 10000 dai

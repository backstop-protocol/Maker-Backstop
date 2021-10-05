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

        bamm = new BAMMJoin(address(vat), address(spotter), "ETH", address(0xb1), address(pot), address(0xfee), 400);

        this.rely(address(vat), address(this));
        vat.suck(address(0x5), address(this), 100000000 ether * 1e27);
        vat.slip("ETH", address(this), 100000000 ether);

        vat.move(address(this), address(u1), 1000000 ether * 1e27);
        vat.move(address(this), address(u2), 1000000 ether * 1e27);
        vat.move(address(this), address(u3), 1000000 ether * 1e27);        

        u1.doHope(vat, bamm);
        u2.doHope(vat, bamm);
        u3.doHope(vat, bamm);
    }

    function testHappy() public {
    }
}

//82.7838828 eth for 10000 dai

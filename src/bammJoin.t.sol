pragma solidity >=0.6.12;

import { DssDeployTestBase, Vat } from "dss-deploy/DssDeploy.t.base.sol";
import { Blipper } from "./blip.sol";
import { BAMMJoin } from "./bammJoin.sol";

contract BammJoinTest is DssDeployTestBase {
    function setUp() override public {
        super.setUp();
        deploy();
    }

    function testBasic() public {
        this.rely(address(dog), address(this));
        this.rely(address(vat), address(this));

        assertEq(uint(1), dog.wards(address(this)));

        Blipper blipper = new Blipper(address(vat), address(spotter), address(dog), "ETH", address(pipETH));
        dog.file("ETH", "clip", address(blipper));
        dog.file("Hole", 10000000e45);
        dog.file("ETH", "hole", 10000000e45);
        dog.file("ETH", "chop", 113e16);        

        blipper.file("vow", address(vow));

        this.rely(address(vat), address(blipper));
        this.rely(address(dog), address(blipper));
        blipper.rely(address(dog));

        weth.mint(1e30);
        weth.approve(address(ethJoin), uint(-1));
        ethJoin.join(address(this), 1e30);
        assertEq(vat.gem("ETH", address(this)), 1e30);

        address u = address(this);
        vat.frob("ETH", u, u, u, 100 ether, 10000 ether);
        assertEq(vat.dai(u), 10000 ether * 1e27);

        BAMMJoin bamm = new BAMMJoin(address(vat), address(spotter), "ETH", address(blipper), address(pot), address(0xfee), 400);
        blipper.file("bprotocol", address(bamm));
        blipper.file("bee", 105e25); /* 5% premium */

        vat.suck(address(0x5), address(this), 1000000 ether * 1e27);
        vat.hope(address(bamm));
        bamm.deposit(20000 ether);
        
        assertEq(bamm.balanceOf(address(this)), 1e18);

        pipETH.poke(bytes32(uint(130 * 1e18)));
        spotter.poke("ETH");
        pipETH.poke(bytes32(uint(130 * 1e18)));

        assertEq(vat.gem("ETH", address(bamm)), uint(0), "gem balance should be 0");
        dog.bark("ETH", u, address(0x123));

        uint daiDebt = 10000 ether * 113 / 100;
        uint normedPrice = uint(130 ether) * 100 / 105;
        uint expectedEth = daiDebt * 1 ether / normedPrice;
        assertEq(vat.gem("ETH", address(bamm)), expectedEth, "gem balance");
    }
}

//82.7838828 eth for 10000 dai

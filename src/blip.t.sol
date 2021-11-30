pragma solidity >=0.6.12;

import { DssDeployTestBase, Vat, Clipper } from "dss-deploy/DssDeploy.t.base.sol";
import { Blipper } from "./blip.sol";
import { BAMMJoin } from "./bammJoin.sol";
import { CToken } from "./mock/ctoken.sol";
import { DSToken } from "ds-token/token.sol";

contract BammJoinTest is DssDeployTestBase {
    BAMMJoin bamm;
    Blipper blipper;
    Clipper clipper;

    function setUp() override public {
        super.setUp();
        deploy();

        this.rely(address(dog), address(this));
        this.rely(address(vat), address(this));

        assertEq(uint(1), dog.wards(address(this)));

        clipper = new Clipper(address(vat), address(spotter), address(dog), "ETH");

        blipper = new Blipper(address(vat), "ETH", address(pipETH));
        dog.file("ETH", "clip", address(blipper));
        dog.file("Hole", 10000000e45);
        dog.file("ETH", "hole", 10000000e45);
        dog.file("ETH", "chop", 113e16);        

        clipper.file("vow", address(vow));
        clipper.file("buf", 2e27);
        clipper.file("tip", 1e27);
        clipper.upchost();

        this.rely(address(vat), address(blipper));
        this.rely(address(vat), address(clipper));        
        this.rely(address(dog), address(blipper));
        blipper.rely(address(dog));
        clipper.rely(address(blipper));
        assertEq(uint(1), clipper.wards(address(blipper)));

        weth.mint(1e30);
        weth.approve(address(ethJoin), uint(-1));
        ethJoin.join(address(this), 1e30);
        assertEq(vat.gem("ETH", address(this)), 1e30);

        address u = address(this);
        vat.frob("ETH", u, u, u, 100 ether, 10000 ether);
        assertEq(vat.dai(u), 10000 ether * 1e27);

        CToken cDai = new CToken(address(dai));

        bamm = new BAMMJoin(address(vat),
                            address(spotter),
                            address(pipETH),
                            "ETH",
                            address(blipper),
                            address(dai),
                            address(daiJoin),
                            address(cDai),
                            address(0xfee),
                            400,
                            address(0xc),
                            address(new DSToken("comp")));
        blipper.file("bprotocol", address(bamm));

        blipper.file("bee", 105e25); /* 5% premium */
        blipper.file("clipper", address(clipper));
        blipper.upparams();

        assertEq(blipper.clipper(), address(clipper));

        vat.suck(address(0x5), address(this), 1000000 ether * 1e27);
        assertEq(vat.dai(address(this)),      1010000 ether * 1e27);
        vat.hope(address(daiJoin));
        daiJoin.exit(address(this), 20000 ether);

        dai.approve(address(bamm), 20000 ether);
        bamm.deposit(20000 ether);
        
        assertEq(bamm.balanceOf(address(this)), 1e18);
        assertEq(vat.gem("ETH", address(bamm)), uint(0), "gem balance should be 0");
        assertEq(dai.balanceOf(address(cDai)), 20000 ether);
        assertEq(cDai.balanceOfUnderlying(address(bamm)), 20000 ether);        
    }

    // liquidation with enough eth to cover debt
    function testHappyBark() public {
        pipETH.poke(bytes32(uint(130 * 1e18)));
        spotter.poke("ETH");
        pipETH.poke(bytes32(uint(130 * 1e18)));

        uint gemBefore = vat.gem("ETH", address(this));
        dog.bark("ETH", address(this), address(0x123));
        uint gemAfter = vat.gem("ETH", address(this));

        uint daiDebt = 10000 ether * 113 / 100;
        uint normedPrice = uint(130 ether) * 100 / 105;
        uint expectedEth = daiDebt * 1 ether / normedPrice;
        assertEq(vat.gem("ETH", address(bamm)), expectedEth, "gem balance");
        assertEq(vat.dai(address(0x123)), 1e27);

        assertEq(vat.dai(address(vow)), daiDebt * 1e27);
        assertEq(dog.Dirt(), 0);
        (,,,uint dirt) = dog.ilks("ETH");
        assertEq(dirt, 0);

        uint deltaGem = 100 ether - expectedEth;
        require(deltaGem > 0, "delta gem is 0");
        assertEq(gemBefore + deltaGem, gemAfter, "testHappyBark: unexpected delta gem");
    }

    // liquidation with enough eth to cover debt and 10% premium
    function testBarkWithLowInk() public {
        pipETH.poke(bytes32(uint(110 * 1e18)));
        spotter.poke("ETH");
        pipETH.poke(bytes32(uint(110 * 1e18)));

        dog.bark("ETH", address(this), address(0x123));

        uint expectedEth = 100 ether;
        assertEq(vat.gem("ETH", address(bamm)), expectedEth, "gem balance low ink");
        assertEq(vat.dai(address(0x123)), 1e27);

        // 100 ether to dai with 5% premium
        uint daiDebt = 100 * (uint(100 ether * 110) / 105);
        assertEq(vat.dai(address(vow)), daiDebt * 1e27);
        assertEq(dog.Dirt(), 0);
        (,,,uint dirt) = dog.ilks("ETH");
        assertEq(dirt, 0);
    }

    // liquidation without enough eth to cover debt and 10% premium
    function testBarkWithClipper() public {
        pipETH.poke(bytes32(uint(99 * 1e18)));
        spotter.poke("ETH");
        pipETH.poke(bytes32(uint(9 * 1e18)));

        uint kickBefore = clipper.kicks();
        dog.bark("ETH", address(this), address(0x123));
        uint kickAfter = clipper.kicks();

        assertEq(kickBefore + 1, kickAfter, "testBarkWithClipper: expected auction to start");
        assertEq(vat.dai(address(0x123)), 1e27);

        uint daiDebt = 10000 ether * 113 / 100;

        assertEq(dog.Dirt(), daiDebt * 1e27);
        (,,,uint dirt) = dog.ilks("ETH");
        assertEq(dirt, daiDebt * 1e27);
    }    
}

//82.7838828 eth for 10000 dai

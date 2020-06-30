// External
const Vat = artifacts.require('Vat');
const GemJoin = artifacts.require('GemJoin');
const DaiJoin = artifacts.require('DaiJoin');
const Weth = artifacts.require("WETH9");
const ERC20 = artifacts.require("TestERC20");
const Jug = artifacts.require('Jug');
const Pot = artifacts.require('Pot');
const End = artifacts.require('End');
const Chai = artifacts.require('Chai');
const GasToken = artifacts.require('GasToken1');

// Common
const ChaiOracle = artifacts.require('ChaiOracle');
const WethOracle = artifacts.require('WethOracle');
const Treasury = artifacts.require('Treasury');

// YDai
const YDai = artifacts.require('YDai');
const Dealer = artifacts.require('Dealer');

// Peripheral
const Splitter = artifacts.require('Splitter');
const Liquidations = artifacts.require('Liquidations');
const EthProxy = artifacts.require('EthProxy');
const Shutdown = artifacts.require('Shutdown');

const helper = require('ganache-time-traveler');
const truffleAssert = require('truffle-assertions');
const { BN, expectRevert, expectEvent } = require('@openzeppelin/test-helpers');
const { toWad, toRay, toRad, addBN, subBN, mulRay, divRay } = require('./shared/utils');

contract('Shutdown - Dealer', async (accounts) =>  {
    let [ owner, user1, user2, user3, user4 ] = accounts;
    let vat;
    let weth;
    let wethJoin;
    let dai;
    let daiJoin;
    let jug;
    let pot;
    let end;
    let chai;
    let gasToken;
    let chaiOracle;
    let wethOracle;
    let treasury;
    let yDai1;
    let yDai2;
    let dealer;
    let splitter;
    let liquidations;
    let ethProxy;
    let shutdown;

    let WETH = web3.utils.fromAscii("WETH");
    let CHAI = web3.utils.fromAscii("CHAI");
    let ilk = web3.utils.fromAscii("ETH-A");
    let Line = web3.utils.fromAscii("Line");
    let spotName = web3.utils.fromAscii("spot");
    let linel = web3.utils.fromAscii("line");

    let snapshot;
    let snapshotId;

    const limits = toRad(10000);
    const spot  = toRay(1.5);
    const rate  = toRay(1.25);
    const chi = toRay(1.2);
    const daiDebt = toWad(120);
    const daiTokens = mulRay(daiDebt, rate);
    const wethTokens = divRay(daiTokens, spot);
    const chaiTokens = divRay(daiTokens, chi);
    const yDaiTokens = daiTokens;
    let maturity1;
    let maturity2;

    const tag  = divRay(toRay(1.0), spot); // Irrelevant to the final users
    const fix  = divRay(toRay(1.0), mulRay(spot, toRay(1.1)));
    const fixedWeth = mulRay(daiTokens, fix);

    const auctionTime = 3600; // One hour

    // Convert eth to weth and use it to borrow `daiTokens` from MakerDAO
    // This function shadows and uses global variables, careful.
    async function getDai(user, daiTokens){
        await vat.hope(daiJoin.address, { from: user });
        await vat.hope(wethJoin.address, { from: user });

        const daiDebt = divRay(daiTokens, rate);
        const wethTokens = divRay(daiTokens, spot);

        await weth.deposit({ from: user, value: wethTokens });
        await weth.approve(wethJoin.address, wethTokens, { from: user });
        await wethJoin.join(user, wethTokens, { from: user });
        await vat.frob(ilk, user, user, user, wethTokens, daiDebt, { from: user });
        await daiJoin.exit(user, daiTokens, { from: user });
    }

    // From eth, borrow `daiTokens` from MakerDAO and convert them to chai
    // This function shadows and uses global variables, careful.
    async function getChai(user, chaiTokens){
        const daiTokens = mulRay(chaiTokens, chi);
        await getDai(user, daiTokens);
        await dai.approve(chai.address, daiTokens, { from: user });
        await chai.join(user, daiTokens, { from: user });
    }

    // Convert eth to weth and post it to yDai
    // This function shadows and uses global variables, careful.
    async function postWeth(user, wethTokens){
        await weth.deposit({ from: user, value: wethTokens });
        await weth.approve(dealer.address, wethTokens, { from: user });
        await dealer.post(WETH, user, user, wethTokens, { from: user });
    }

    // Convert eth to chai and post it to yDai
    // This function shadows and uses global variables, careful.
    async function postChai(user, chaiTokens){
        await getChai(user, chaiTokens);
        await chai.approve(dealer.address, chaiTokens, { from: user });
        await dealer.post(CHAI, user, user, chaiTokens, { from: user });
    }

    // Add a new yDai series
    // This function uses global variables, careful.
    async function addYDai(maturity){
        yDai = await YDai.new(
            vat.address,
            jug.address,
            pot.address,
            treasury.address,
            maturity,
            "Name",
            "Symbol",
            { from: owner },
        );
        await dealer.addSeries(yDai.address, { from: owner });
        await yDai.grantAccess(dealer.address, { from: owner });
        await treasury.grantAccess(yDai.address, { from: owner });
        await yDai.grantAccess(shutdown.address, { from: owner });
        return yDai;
    }

    beforeEach(async() => {
        snapshot = await helper.takeSnapshot();
        snapshotId = snapshot['result'];

        // Setup vat, join and weth
        vat = await Vat.new();
        await vat.init(ilk, { from: owner }); // Set ilk rate (stability fee accumulator) to 1.0

        weth = await Weth.new({ from: owner });
        wethJoin = await GemJoin.new(vat.address, ilk, weth.address, { from: owner });

        dai = await ERC20.new(0, { from: owner });
        daiJoin = await DaiJoin.new(vat.address, dai.address, { from: owner });

        await vat.file(ilk, spotName, spot, { from: owner });
        await vat.file(ilk, linel, limits, { from: owner });
        await vat.file(Line, limits);

        // Setup jug
        jug = await Jug.new(vat.address);
        await jug.init(ilk, { from: owner }); // Set ilk duty (stability fee) to 1.0

        // Setup pot
        pot = await Pot.new(vat.address);

        // Setup end
        end = await End.new({ from: owner });
        await end.file(web3.utils.fromAscii("vat"), vat.address);

        // Permissions
        await vat.rely(vat.address, { from: owner });
        await vat.rely(wethJoin.address, { from: owner });
        await vat.rely(daiJoin.address, { from: owner });
        await vat.rely(jug.address, { from: owner });
        await vat.rely(pot.address, { from: owner });
        await vat.rely(end.address, { from: owner });
        await vat.hope(daiJoin.address, { from: owner });

        // Setup chai
        chai = await Chai.new(
            vat.address,
            pot.address,
            daiJoin.address,
            dai.address,
            { from: owner },
        );

        // Setup GasToken
        gasToken = await GasToken.new();

        // Setup WethOracle
        wethOracle = await WethOracle.new(vat.address, { from: owner });

        // Setup ChaiOracle
        chaiOracle = await ChaiOracle.new(pot.address, { from: owner });

        // Set treasury
        treasury = await Treasury.new(
            dai.address,
            chai.address,
            chaiOracle.address,
            weth.address,
            daiJoin.address,
            wethJoin.address,
            vat.address,
            { from: owner },
        );

        // Setup Dealer
        dealer = await Dealer.new(
            treasury.address,
            dai.address,
            weth.address,
            wethOracle.address,
            chai.address,
            chaiOracle.address,
            gasToken.address,
            { from: owner },
        );
        await treasury.grantAccess(dealer.address, { from: owner });

        // Setup Splitter
        splitter = await Splitter.new(
            treasury.address,
            dealer.address,
            { from: owner },
        );
        await dealer.grantAccess(splitter.address, { from: owner });
        await treasury.grantAccess(splitter.address, { from: owner });

        // Setup yDai
        const block = await web3.eth.getBlockNumber();
        maturity1 = (await web3.eth.getBlock(block)).timestamp + 1000;
        yDai1 = await YDai.new(
            vat.address,
            jug.address,
            pot.address,
            treasury.address,
            maturity1,
            "Name",
            "Symbol",
            { from: owner },
        );
        await dealer.addSeries(yDai1.address, { from: owner });
        await yDai1.grantAccess(dealer.address, { from: owner });
        await treasury.grantAccess(yDai1.address, { from: owner });

        maturity2 = (await web3.eth.getBlock(block)).timestamp + 2000;
        yDai2 = await YDai.new(
            vat.address,
            jug.address,
            pot.address,
            treasury.address,
            maturity2,
            "Name2",
            "Symbol2",
            { from: owner },
        );
        await dealer.addSeries(yDai2.address, { from: owner });
        await yDai2.grantAccess(dealer.address, { from: owner });
        await treasury.grantAccess(yDai2.address, { from: owner });

        // Setup EthProxy
        ethProxy = await EthProxy.new(
            weth.address,
            gasToken.address,
            dealer.address,
            { from: owner },
        );

        // Setup Liquidations
        liquidations = await Liquidations.new(
            dai.address,
            treasury.address,
            dealer.address,
            auctionTime,
            { from: owner },
        );
        await dealer.grantAccess(liquidations.address, { from: owner });
        await treasury.grantAccess(liquidations.address, { from: owner });

        // Setup Shutdown
        shutdown = await Shutdown.new(
            vat.address,
            daiJoin.address,
            weth.address,
            wethJoin.address,
            jug.address,
            pot.address,
            end.address,
            chai.address,
            chaiOracle.address,
            treasury.address,
            dealer.address,
            liquidations.address,
            { from: owner },
        );
        await treasury.grantAccess(shutdown.address, { from: owner });
        await treasury.registerShutdown(shutdown.address, { from: owner });
        await dealer.grantAccess(shutdown.address, { from: owner });
        await yDai1.grantAccess(shutdown.address, { from: owner });
        await yDai2.grantAccess(shutdown.address, { from: owner });
        await shutdown.addSeries(yDai1.address, { from: owner });
        await shutdown.addSeries(yDai2.address, { from: owner });
        await liquidations.grantAccess(shutdown.address, { from: owner });

        // Tests setup
        await pot.setChi(chi, { from: owner });
        await vat.fold(ilk, vat.address, subBN(rate, toRay(1)), { from: owner }); // Fold only the increase from 1.0
        await vat.hope(daiJoin.address, { from: owner });
        await vat.hope(wethJoin.address, { from: owner });
        await treasury.grantAccess(owner, { from: owner });
        await end.rely(owner, { from: owner });       // `owner` replaces MKR governance
    });

    afterEach(async() => {
        await helper.revertToSnapshot(snapshotId);
    });

    /* it("does not attempt to settle treasury debt until Dss shutdown initiated", async() => {
        await expectRevert(
            shutdown.settleTreasury({ from: owner }),
            "Shutdown: End.sol not caged",
        );
    }); */

    describe("with chai savings", () => {
        beforeEach(async() => {
            await getChai(owner, chaiTokens.mul(10));
            await chai.transfer(treasury.address, chaiTokens.mul(10), { from: owner });
        });

        it("chai savings are added to profits", async() => {
            await shutdown.skim(user1, { from: owner });

            assert.equal(
                await chai.balanceOf(user1),
                chaiTokens.mul(10).toString(),
                'User1 should have ' + chaiTokens.mul(10).toString() + ' chai wei',
            );
        });

        it("chai held as collateral doesn't count as profits", async() => {
            await getChai(user2, chaiTokens);
            await chai.approve(dealer.address, chaiTokens, { from: user2 });
            await dealer.post(CHAI, user2, user2, chaiTokens, { from: user2 });

            await shutdown.skim(user1, { from: owner });

            assert.equal(
                await chai.balanceOf(user1),
                chaiTokens.mul(10).toString(),
                'User1 should have ' + chaiTokens.mul(10).toString() + ' chai wei',
            );
        });

        describe("with dai debt", () => {
            beforeEach(async() => {
                await weth.deposit({ from: owner, value: wethTokens });
                await weth.approve(wethJoin.address, wethTokens, { from: owner });
                await weth.transfer(treasury.address, wethTokens, { from: owner });
                await treasury.pushWeth({ from: owner });
                await treasury.pullDai(owner, daiTokens, { from: owner });
            });
    
            it("deduces dai debt from profits", async() => {
                await shutdown.skim(user1, { from: owner });
    
                assert.equal(
                    await chai.balanceOf(user1),
                    chaiTokens.mul(9).toString(),
                    'User1 should have ' + chaiTokens.mul(9).toString() + ' chai wei',
                );
            });
        });
    });
});
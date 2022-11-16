// import { ethers } from "hardhat";
// import { expect } from "chai";
// import "@nomicfoundation/hardhat-chai-matchers";
// import { HardhatRuntimeEnvironment } from "hardhat/types";
// import {
//   DOS,
//   DOS__factory,
//   MockValueOracle__factory,
//   PortfolioLogic__factory,
//   TestERC20__factory,
//   WETH9__factory,
//   TestNFT__factory,
//   MockNFTOracle__factory,
// } from "../../typechain-types";
// import { toWei } from ";
// import { getEventParams } from "../../../common/src/Events";
// import { BigNumber, Contract, Signer } from "ethers";

// const setupDos = deployments.createFixture(
//   async ({ deployments, ethers, waffle }: HardhatRuntimeEnvironment) => {
//     await deployments.fixture();

//     const [owner, user, user2] = await ethers.getSigners();

//     const usdc = await new TestERC20__factory(owner).deploy(
//       "USD Coin",
//       "USDC",
//       18
//     );
//     const weth = await new WETH9__factory(owner).deploy();
//     const nft = await new TestNFT__factory(owner).deploy();

//     const usdcOracle = await new MockValueOracle__factory(owner).deploy();
//     const wethOracle = await new MockValueOracle__factory(owner).deploy();

//     await usdcOracle.setPrice(toWei(1));
//     await wethOracle.setPrice(2000 * 1000000);

//     const nftOracle = await new MockNFTOracle__factory(owner).deploy();

//     await nftOracle.setPrice(1, toWei(100));

//     const dos = await new DOS__factory(owner).deploy(owner.address);

//     await dos.setConfig({
//       liqFraction: toWei(0.8),
//       fractionalReserveLeverage: 9,
//     });

//     // No interest which would include time sensitive calculations
//     await dos.addERC20Asset(
//       usdc.address,
//       "USD Coin",
//       "USDC",
//       6,
//       usdcOracle.address,
//       toWei(0.9),
//       toWei(0.9),
//       0
//     );
//     await dos.addERC20Asset(
//       weth.address,
//       "Wrapped ETH",
//       "WETH",
//       18,
//       wethOracle.address,
//       toWei(0.9),
//       toWei(0.9),
//       0
//     );

//     return {
//       owner,
//       user,
//       user2,
//       usdc,
//       weth,
//       usdcOracle,
//       wethOracle,
//       nft,
//       nftOracle,
//       dos,
//     };
//   }
// );

// async function CreatePortfolio(dos: DOS, signer: Signer) {
//   const { portfolio } = await getEventParams(
//     await dos.connect(signer).createPortfolio(),
//     dos,
//     "PortfolioCreated"
//   );
//   return PortfolioLogic__factory.connect(portfolio as string, signer);
// }

// function createCall(c: Contract, funcName: string, params: any[]) {
//   return {
//     to: c.address,
//     callData: c.interface.encodeFunctionData(funcName, params),
//     value: 0,
//   };
// }

// const tenthoushandUSD = toWei(10000, 6);

// describe("Dos tests", () => {
//   it("User can create portfolio", async () => {
//     const { owner, user, dos } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     expect(await portfolio.owner()).to.equal(user.address);
//   });

//   it("User can deposit money", async () => {
//     const { owner, user, dos, usdc } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//     ]);
//     expect(await usdc.balanceOf(dos.address)).to.equal(tenthoushandUSD);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//   });

//   it("User can transfer money", async () => {
//     const { owner, user, user2, dos, usdc } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//       createCall(dos, "transfer", [0, portfolio2.address, tenthoushandUSD]),
//     ]);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(toWei(0));
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//   });

//   it("User can deposit and transfer money in arbitrary order", async () => {
//     const { owner, user, user2, dos, usdc } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "transfer", [0, portfolio2.address, tenthoushandUSD]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//     ]);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(0n);
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//   });

//   it("User cannot send more then they own", async () => {
//     const { owner, user, user2, dos, usdc } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     await expect(
//       portfolio.executeBatch([
//         createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//         createCall(dos, "transfer", [
//           0,
//           portfolio2.address,
//           tenthoushandUSD + tenthoushandUSD,
//         ]),
//         createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//       ])
//     ).to.be.revertedWith("Result of operation is not sufficient liquid");
//   });

//   it("User can send more asset then they have", async () => {
//     const { owner, user, user2, dos, usdc, weth } = await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     // Put WETH in system so we can borrow weth
//     const portfolio3 = await CreatePortfolio(dos, user);
//     await weth.mint(portfolio3.address, toWei(0.25));
//     await portfolio3.executeBatch([
//       createCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "depositAsset", [1, toWei(0.25)]),
//     ]);

//     const oneEth = toWei(1);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "transfer", [1, portfolio2.address, oneEth]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//     ]);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//     expect(await dos.viewBalance(portfolio.address, 1)).to.equal(-oneEth);
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(0);
//     expect(await dos.viewBalance(portfolio2.address, 1)).to.equal(oneEth);
//   });

//   it("Non-solvent position can be liquidated", async () => {
//     const { owner, user, user2, dos, usdc, weth, wethOracle } =
//       await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     // Put WETH in system so we can borrow weth
//     const portfolio3 = await CreatePortfolio(dos, user);
//     await weth.mint(portfolio3.address, toWei(0.25));
//     await portfolio3.executeBatch([
//       createCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "depositAsset", [1, toWei(0.25)]),
//     ]);

//     await usdc.mint(portfolio.address, tenthoushandUSD);
//     const oneEth = toWei(1);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "transfer", [1, portfolio2.address, oneEth]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//     ]);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//     expect(await dos.viewBalance(portfolio.address, 1)).to.equal(-oneEth);
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(0);
//     expect(await dos.viewBalance(portfolio2.address, 1)).to.equal(oneEth);

//     // Increase price of eth such that first portfolio is illiquid
//     await wethOracle.setPrice(9000 * 1000000);

//     await portfolio2.executeBatch([
//       createCall(dos, "liquidate", [portfolio.address]),
//     ]);

//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(toWei(800, 6));
//     expect(await dos.viewBalance(portfolio.address, 1)).to.equal(0);
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(
//       tenthoushandUSD - toWei(800, 6)
//     );
//     expect(await dos.viewBalance(portfolio2.address, 1)).to.equal(0);
//   });

//   it("Solvent position can be liquidated", async () => {
//     const { owner, user, user2, dos, usdc, weth, wethOracle } =
//       await setupDos();
//     const portfolio = await CreatePortfolio(dos, user);
//     const portfolio2 = await CreatePortfolio(dos, user2);

//     // Put WETH in system so we can borrow weth
//     const portfolio3 = await CreatePortfolio(dos, user);
//     await weth.mint(portfolio3.address, toWei(0.25));
//     await portfolio3.executeBatch([
//       createCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "depositAsset", [1, toWei(0.25)]),
//     ]);

//     await usdc.mint(portfolio.address, tenthoushandUSD);

//     const oneEth = toWei(1);

//     await portfolio.executeBatch([
//       createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
//       createCall(dos, "transfer", [1, portfolio2.address, oneEth]),
//       createCall(dos, "depositAsset", [0, tenthoushandUSD]),
//     ]);
//     expect(await dos.viewBalance(portfolio.address, 0)).to.equal(
//       tenthoushandUSD
//     );
//     expect(await dos.viewBalance(portfolio.address, 1)).to.equal(-oneEth);
//     expect(await dos.viewBalance(portfolio2.address, 0)).to.equal(0);
//     expect(await dos.viewBalance(portfolio2.address, 1)).to.equal(oneEth);

//     await expect(
//       portfolio2.executeBatch([
//         createCall(dos, "liquidate", [portfolio.address]),
//       ])
//     ).to.be.revertedWith("Portfolio is not liquidatable");
//   });

//   describe("NFT", () => {
//     describe("depositNft", () => {
//       it(
//         "when user owns the NFT " +
//           "should change ownership of the NFT from the user to DOS " +
//           "and add NFT to the user DOS portfolio",
//         async () => {
//           const { user, dos, nft, nftOracle } = await setupDos();
//           const portfolio = await CreatePortfolio(dos, user);
//           await (
//             await dos.addNftInfo(nft.address, nftOracle.address, toWei(0.5))
//           ).wait();
//           const mintTx = await nft.mint(user.address);
//           const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
//           const tokenId = mintEventArgs[0] as BigNumber;
//           await (await nft.connect(user).approve(dos.address, tokenId)).wait();

//           const depositNftTx = await portfolio.executeBatch([
//             createCall(dos, "depositNft", [nft.address, tokenId]),
//           ]);
//           await depositNftTx.wait();

//           expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
//           const userNfts = await dos.viewNfts(portfolio.address);
//           expect(userNfts).to.eql([[nft.address, tokenId]]);
//         }
//       );

//       it(
//         "when portfolio owns the NFT " +
//           "should change ownership of the NFT from portfolio to DOS " +
//           "and add NFT to the user DOS portfolio",
//         async () => {
//           const { user, dos, nft, nftOracle } = await setupDos();
//           const portfolio = await CreatePortfolio(dos, user);
//           await (
//             await dos.addNftInfo(nft.address, nftOracle.address, toWei(0.5))
//           ).wait();
//           const mintTx = await nft.mint(portfolio.address);
//           const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
//           const tokenId = mintEventArgs[0] as BigNumber;

//           const depositNftTx = await portfolio.executeBatch([
//             createCall(nft, "approve", [dos.address, tokenId]),
//             createCall(dos, "depositNft", [nft.address, tokenId]),
//           ]);
//           await depositNftTx.wait();

//           expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
//           const userNfts = await dos.viewNfts(portfolio.address);
//           expect(userNfts).to.eql([[nft.address, tokenId]]);
//         }
//       );

//       it("when NFT contract is not registered should revert the deposit", async () => {
//         const { user, dos, nft } = await setupDos();
//         const portfolio = await CreatePortfolio(dos, user);
//         const mintTx = await nft.mint(portfolio.address);
//         const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
//         const tokenId = mintEventArgs[0] as BigNumber;

//         const depositNftTx = portfolio.executeBatch([
//           createCall(nft, "approve", [dos.address, tokenId]),
//           createCall(dos, "depositNft", [nft.address, tokenId]),
//         ]);

//         await expect(depositNftTx).to.be.revertedWith(
//           "Cannot add NFT of unknown NFT contract"
//         );
//       });

//       it("when user is not an owner of NFT should revert the deposit", async () => {
//         const { user, user2, dos, nft, nftOracle } = await setupDos();
//         const portfolio = await CreatePortfolio(dos, user);
//         const portfolio2 = await CreatePortfolio(dos, user2);
//         await (
//           await dos.addNftInfo(nft.address, nftOracle.address, toWei(0.5))
//         ).wait();
//         const mintTx = await nft.mint(portfolio.address);
//         const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
//         const tokenId = mintEventArgs[0] as BigNumber;
//         const approveNftDepositTx = await portfolio.executeBatch([
//           createCall(nft, "approve", [dos.address, tokenId]),
//         ]);
//         await approveNftDepositTx.wait();

//         const depositNftTx = portfolio2.executeBatch([
//           createCall(dos, "depositNft", [nft.address, tokenId]),
//         ]);

//         await expect(depositNftTx).to.be.revertedWith(
//           "NFT must be owned the the user or user's portfolio"
//         );
//       });

//       it("when called directly on DOS should revert the deposit", async () => {
//         const { user, dos, nft, nftOracle } = await setupDos();
//         await (
//           await dos.addNftInfo(nft.address, nftOracle.address, toWei(0.5))
//         ).wait();
//         const mintTx = await nft.mint(user.address);
//         const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
//         const tokenId = mintEventArgs[0] as BigNumber;
//         await (await nft.connect(user).approve(dos.address, tokenId)).wait();

//         const depositNftTx = dos.depositNft(nft.address, tokenId);

//         await expect(depositNftTx).to.be.revertedWith(
//           "Only portfolio can execute"
//         );
//       });
//     });

//     describe("claimNft", () => {
//       it("when called not with portfolio should revert", async () => {});

//       it("when user is not the owner of the deposited NFT should revert");

//       it(
//         "when user owns the deposited NFT " +
//           "should change ownership of the NFT from DOS to user's portfolio " +
//           "and remove NFT from the user DOS portfolio"
//       );
//     });
//   });
// });

# Supa Contracts

the infra of defi

## Installation

clone the project and make sure you have a Node version > 16

## To complie

```bash
npx hardhat compile
```

## To run test

```bash
npx hardhat test
```

## Contributing

Pull requests are welcome. For major changes, please open an issue first
to discuss what you would like to change.

Please make sure to update tests as appropriate.

## To run locally

Make sure you run update the typechain folder to get the latest contract build.

```bash
yarn typechain
```

Make sure you have docker version 4.12.0 (dont upgrade to the latest it causes issues).

then run

```bash
yarn start
```

Then

```bash
yarn setupLocalhost
```

Check the deployments folder for the updated addresses. If they have changed make use to take the Supa address and put it in the subgraph folder: subgraph.yaml and networks.json

Now run

```bash
yarn graph-local
```

Open a new terminal and run

```bash
yarn create-local
```

Then run

```bash
yarn deploy-local
```

On the supa-frontend repo make sure to copy and paste the contract addresses to the addresses.json file.

run

```bash
yarn run dev
```

You might have to reset your nonce on metamask to interact with things.

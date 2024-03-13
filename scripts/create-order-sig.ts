import { ethers } from "hardhat";
// @ts-ignore
import { base58_to_binary } from "base58-js";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	const random = ethers.utils.keccak256(keypair.publicKey);
	console.log({ random });
	const [owner] = await ethers.getSigners();

	let destEmitter;
	if (!destAuth) {
		destEmitter = HashZero;
	} else {
		destEmitter = ethToBytes32(destAuth);
	}

	/*
	struct OrderParams {
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 auctionMode;
		bytes32 random;
		bytes32 destEmitter;
	} */
	const params = {
		tokenOut: base58ToBytes32('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
		minAmountOut: 80,
		gasDrop: 0,
		destAddr: base58ToBytes32('35V85aqyssnda35TYsjgd45vTVuK8swuzsht59LNNuDU'),
		destChainId: 1,
		referrerAddr: base58ToBytes32("3f6rtWrGw6Vp3RLUw5hVfe6sG5ePzThpFB7Vi8LL54mD"),
		referrerBps: 3,
		auctionMode: 2,
		random,
		destEmitter
	}

	const keyTypes = [
		"bytes32", "uint16", "bytes32", "uint64", 
		"bytes32", "uint16", "bytes32", "uint64",
		"uint64", "bytes32", "uint8", "uint8", 
		"uint8", "bytes32"
	];

	console.log('keyTypes length', keyTypes.length);

	const usdc = '0x5425890298aed601595a70AB815c96711a31Bc65';
	const keyValues = [
		ethToBytes32(owner.address),	// trader: 
		6,	// srcChainId: 
		ethToBytes32(usdc),	// tokenIn: 
		100,	// amountIn: 
		params.destAddr,	// destAddr: 
		params.destChainId,	// destChainId: 
		params.tokenOut,	// tokenOut: 
		params.minAmountOut,	// minAmountOut: 
		params.gasDrop,	// gasDrop: 
		params.referrerAddr,	// referrerAddr: 
		params.referrerBps,	// referrerBps: 
		0,	// protocolBps: 
		params.auctionMode,	// auctionMode: 
		params.random	// random: 
	];

	// encoded = abi.encodePacked(
	// 	key.trader,
	// 	key.srcChainId,
	// 	key.tokenIn,
	// 	key.amountIn,
	// 	key.destAddr,
	// 	key.destChainId,
	// 	key.tokenOut,
	// 	key.minAmountOut,
	// 	key.gasDrop,
	// 	key.referrerAddr,
	// 	key.referrerBps,
	// 	key.protocolBps,
	// 	key.auctionMode,
	// 	key.random
	// );

	const packedKey = ethers.utils.solidityPack(keyTypes, keyValues);
	const orderHash = ethers.utils.keccak256(packedKey);
	console.log({ orderHash });

	const domain = {
		name: "Mayan Swift v1.0",
		chainId: 6, 
		verifyingContract: swift.address
	}

	const types = {
		CreateOrder: [
			{ name: "orderHash", type: "bytes32" },
		],
	};
	
	const message = { orderHash };

	const orderHashSigned = await owner._signTypedData(domain, types, message);

	console.log({ signature: orderHashSigned });

	const data = {
		domain: {
			name: 'USD Coin',
			version: '2',
			chainId: 43113,
			verifyingContract: usdc,
	  	},
		types: {
		  ReceiveWithAuthorization: [
			{ name: "from", type: "address" },
			{ name: "to", type: "address" },
			{ name: "value", type: "uint256" },
			{ name: "validAfter", type: "uint256" },
			{ name: "validBefore", type: "uint256" },
			{ name: "nonce", type: "bytes32" },
		  ],
		},
		value: {
		  from: owner.address,
		  to: swift.address,
		  value: 100,
		  validAfter: 0,
		  validBefore: Math.floor(Date.now() / 1000) + 3600, // Valid for an hour
		  nonce: orderHash,
		},
	  };

	  console.log({data});

	const sig = await owner._signTypedData(data.domain, data.types, data.value);

	const transferParams = {
		from: data.value.from,
		validAfter: data.value.validAfter,
		validBefore: data.value.validBefore
	}
	const tx = await swift.createOrderWithSig(usdc, 100, params, orderHashSigned, transferParams, sig);


	////////////////////////////////////
	const receipt = await tx.wait();
	console.log({ receipt });
}

function ethToBytes32(address: string) {
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}
	return '0x' + '000000000000000000000000' + address.substring(2);
}

function base58ToBytes32(address: string) {
	return '0x' + Buffer.from(base58_to_binary(address)).toString('hex');
}

main(process.env.SWIFT_ADDR, process.env.DEST_AUTH).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
const HashZero = ethers.constants.HashZero;



export interface Signature {
	v: number;
	r: string;
	s: string;
  }
  
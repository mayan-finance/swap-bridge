import { PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import { ethers } from "hardhat";

async function main(localMctpAddr: string, remoteMctpAddr: string) {
	const MayanCircle = await ethers.getContractFactory("MayanCircle");
	const mayanCircle = await MayanCircle.attach(localMctpAddr);

	const HashZero = ethers.constants.HashZero;
	const [owner] = await ethers.getSigners();

	const criteria = {
		transferDeadline: new Date().getTime() + 1000 * 60 * 60,
		swapDeadline: new Date().getTime() + 1000 * 60 * 60,
		tokenOutAddr: base58ToBytes32('4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU'),
		amountOutMin: 27510009,
		gasDrop: 600009,
		customPayload: '0x'
	}

	const recipient = {
		destAddr: base58ToBytes32('3f6rtWrGw6Vp3RLUw5hVfe6sG5ePzThpFB7Vi8LL54mD'),
		destDomain: 5,
		mayanAddr: getMainPdaAta(remoteMctpAddr),
		callerAddr: getCallerPda(remoteMctpAddr),
		refundAddr: base58ToBytes32('35V85aqyssnda35TYsjgd45vTVuK8swuzsht59LNNuDU')
	}

	const fees = {
		settleFee: 43503,
		referrerBps: 7
	}

	const usdc = "0x07865c6e87b9f70255377e024ace6630c1eaa37f";
	const ERC20_ABI = [
		"function approve(address spender, uint256 value) public returns (bool)"
	];
	const token = new ethers.Contract(usdc, ERC20_ABI, owner);
	const approveTx = await token.approve(mayanCircle.address, 27510009);
	await approveTx.wait();

	const tx = await mayanCircle.swap(recipient, criteria, fees, usdc, 27510009, base58ToBytes32('EU8z368kxJ4VzLfdpNG774L6DpAnav9d9cBBpbyH9Rr2'));
	const receipt = await tx.wait();
	console.log({ receipt });
}

function getMainPdaAta(programAddr: string) {
	const [mainAddr] = PublicKey.findProgramAddressSync([
		Buffer.from('MAIN'),
	], new PublicKey(programAddr));

	const mainMint = getAssociatedTokenAddressSync(new PublicKey('4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU'), mainAddr, true);
	return '0x' + mainMint.toBuffer().toString('hex');
}

function getCallerPda(programAddr: string) {
	const [emitterSwift] = PublicKey.findProgramAddressSync([
		Buffer.from('CCTPCALLER'),
	], new PublicKey(programAddr));
	return '0x' + emitterSwift.toBuffer().toString('hex');
}

function ethToBytes32(address: string) {
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}
	return '0x' + '000000000000000000000000' + address.substring(2);
}

function base58ToBytes32(address: string) {
	return '0x' + new PublicKey(address).toBuffer().toString('hex');
}

if (!process.env.LOCAL_MCTP) {
	console.log('variable LOCAL_MCTP is required');
	process.exit(1);
}

if (!process.env.REMOTE_MCTP) {
	console.log('variable REMOTE_MCTP is required');
	process.exit(1);
}

main(process.env.LOCAL_MCTP, process.env.REMOTE_MCTP).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
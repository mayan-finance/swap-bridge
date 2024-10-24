import { ethers } from "hardhat";

async function main(swapProtocol: string, mayanProtocol: string) {
	const [guardian] = await ethers.getSigners();
	const MayanForwarder = await ethers.getContractFactory("MayanForwarder");

	const forwarder = await MayanForwarder.deploy(guardian.address, [swapProtocol], [mayanProtocol]);

	console.log(`Deployed Forwarder at ${forwarder.address}`);
}

if (!process.env.MAYAN_PROTOCOL) {
    console.log('variables MAYAN_PROTOCOL is required');
    process.exit(1);
}
if (!process.env.SWAP_PROTOCOL) {
    console.log('variables SWAP_PROTOCOL is required');
    process.exit(1);
}

main(process.env.SWAP_PROTOCOL, process.env.MAYAN_PROTOCOL).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
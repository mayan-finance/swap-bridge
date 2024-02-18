import { ethers } from "hardhat";

async function main(localMctpAddr: string) {
	const MayanCircle = await ethers.getContractFactory("MayanCircle");
	const mayanCircle = await MayanCircle.attach(localMctpAddr);

	const tx = await mayanCircle.setDomainToChainId(5, 1);
	const receipt = await tx.wait();
	console.log({ receipt });
}


if (!process.env.LOCAL_MCTP) {
	console.log('variable LOCAL_MCTP is required');
	process.exit(1);
}


main(process.env.LOCAL_MCTP).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
import { ethers } from "hardhat";

async function main() {
	const [operator] = await ethers.getSigners();
	const FeeManager = await ethers.getContractFactory("FeeManager");
	const feeManager = await FeeManager.deploy(operator.address);

	console.log(`Deployed FeeManager at ${feeManager.address}`);
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
import { ethers } from "hardhat";

async function main(swiftAddr: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	console.log({ swiftAddr })
	const swift = await Swift.attach(swiftAddr);

	// const order = await swift.getOrder('0xb0e81833ff1aa58792f42eee7d0a8cbaa07bd45933b928777449ed28c37924fc');
	// console.log({ order });

	const vaa = "";
	const tx = await swift.releaseOrder(vaa);
	const receipt = await tx.wait();
	console.log({ receipt });
}

main(process.env.SWIFT_ADDR).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
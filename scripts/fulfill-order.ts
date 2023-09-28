import { ethers } from "hardhat";

async function main(swiftAddr: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	console.log({ swiftAddr })
	const swift = await Swift.attach(swiftAddr);

	// const ERC20_ABI = [
	// 	"function approve(address spender, uint256 value) public returns (bool)"
	//   ];
	// const busd = "0xe9e7cea3dedca5984780bafc599bd69add087d56";
	// const [owner] = await ethers.getSigners();
	// const token = new ethers.Contract(busd, ERC20_ABI, owner);
	// const approveTx = await token.approve(swift.address, "5000000000000");
	// await approveTx.wait();

	const vaa = "";

	const tx = await swift.fulfillOrder(vaa, addressToBytes32("0x5Acf4E865604AB620Fb84ACc047B990F2D2856FD"), { value: "4000000000000" });
	const receipt = await tx.wait();
	console.log({ receipt });
}

function addressToBytes32(address: string) {
	// Ensure the address starts with '0x'
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}

	// Remove the '0x' prefix and pad it with 24 zeroes to get bytes32
	return '0x' + '000000000000000000000000' + address.substring(2);
}

main(process.env.SWIFT_ADDR).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
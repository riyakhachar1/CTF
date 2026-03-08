import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import keyPairJson from "../keypair.json" with { type: "json" };

/**
 *
 * Global variables
 *
 * These variables can be used throughout the exercise below.
 *
 */
const keypair = Ed25519Keypair.fromSecretKey(keyPairJson.privateKey);
const suiClient = new SuiGrpcClient({
	network: 'testnet',
	baseUrl: 'https://fullnode.testnet.sui.io:443',
});

const PACKAGE_ID =
	'0xd56e5075ba297f9e37085a37bb0abba69fabdf9987f8f4a6086a3693d88efbfd';

const CLOCK_OBJECT_ID = '0x6';

function sleep(ms: number) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

(async () => {
	while (true) {
		try {
			const tx = new Transaction();

			const flag = tx.moveCall({
				target: `${PACKAGE_ID}::moving_window::extract_flag`,
				arguments: [tx.object(CLOCK_OBJECT_ID)],
			});

			tx.transferObjects([flag], keypair.toSuiAddress());

			const result = await suiClient.signAndExecuteTransaction({
				signer: keypair,
				transaction: tx,
				options: {
					showEffects: true,
					showObjectChanges: true,
					showEvents: true,
				},
			});

			console.log("Success!");
			console.log("Digest:", result.digest);
			console.dir(result, { depth: null });
			break;
		} catch (error: any) {
			const msg = String(error?.message || error);

			if (msg.includes("insufficient SUI balance")) {
				console.error("Not enough testnet SUI for gas.");
				console.error("Fund this address, then rerun:");
				console.error(keypair.toSuiAddress());
				process.exit(1);
			}

			console.log("Window closed or tx failed, retrying in 5 seconds...");
			console.error(error);
			await sleep(5000);
		}
	}
})();

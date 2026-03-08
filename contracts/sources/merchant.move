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
const COST_PER_FLAG = 5849000n;

// USDC on Sui testnet (Circle)
const USDC_TYPE = '0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC';
const USDC_COIN_TYPE = `0x2::coin::Coin<${USDC_TYPE}>`;

async function getAllUsdcCoins(owner: string): Promise<{ objectId: string; balance: string }[]> {
	// listCoins with coinType can be unreliable for custom types; try listOwnedObjects as fallback
	let coins: { objectId: string; balance: string }[] = [];
	let cursor: string | null = null;

	const listResult = await suiClient.listCoins({
		owner,
		coinType: USDC_COIN_TYPE,
		limit: 50,
		cursor,
	});
	for (const c of listResult.objects) {
		coins.push({ objectId: c.objectId, balance: c.balance });
	}

	// If listCoins returned nothing, try listOwnedObjects with USDC type to get coin objects
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
				// Coin wraps Balance; JSON may have "balance" or nested structure
				let balance = '0';
				if (obj.json && typeof obj.json === 'object') {
					const j = obj.json as Record<string, unknown>;
					if (typeof j.balance === 'string') balance = j.balance;
					else if (j.balance && typeof j.balance === 'object' && 'value' in (j.balance as object))
						balance = String((j.balance as { value: string }).value);
				}
				coins.push({ objectId: obj.objectId, balance });
			}
			objCursor = res.hasNextPage ? res.cursor : null;
		} while (objCursor);
	}

	// If still no coins, list all owned objects and filter by type (type filter can be strict)
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
				if (!obj.type || !obj.type.includes('usdc') || !obj.type.includes('Coin')) continue;
				let balance = '0';
				if (obj.json && typeof obj.json === 'object') {
					const j = obj.json as Record<string, unknown>;
					if (typeof j.balance === 'string') balance = j.balance;
					else if (j.balance && typeof j.balance === 'object' && 'value' in (j.balance as object))
						balance = String((j.balance as { value: string }).value);
				}
				coins.push({ objectId: obj.objectId, balance });
			}
			objCursor = res.hasNextPage ? res.cursor : null;
		} while (objCursor);
	} else {
		// Paginate listCoins if there are more
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
	}

	return coins;
}

(async () => {
	const address = keypair.getPublicKey().toSuiAddress();
	const coins = await getAllUsdcCoins(address);
	const totalBalance = coins.reduce((sum, c) => sum + BigInt(c.balance), 0n);

	if (totalBalance < COST_PER_FLAG) {
		throw new Error(
			`Insufficient USDC. Need ${COST_PER_FLAG} (${Number(COST_PER_FLAG) / 1e6} USDC), have ${totalBalance}. Get testnet USDC from a faucet.`
		);
	}

	const tx = new Transaction();

	// Find a coin with enough balance, or we'll merge then split
	let paymentCoin: ReturnType<Transaction['object']>;
	const coinWithEnough = coins.find((c) => BigInt(c.balance) >= COST_PER_FLAG);

	if (coinWithEnough) {
		if (BigInt(coinWithEnough.balance) === COST_PER_FLAG) {
			paymentCoin = tx.object(coinWithEnough.objectId);
		} else {
			[paymentCoin] = tx.splitCoins(tx.object(coinWithEnough.objectId), [COST_PER_FLAG]);
		}
	} else {
		// Merge all USDC into the first coin, then split
		const [head, ...rest] = coins;
		if (rest.length > 0) {
			tx.mergeCoins(
				tx.object(head.objectId),
				rest.map((c) => tx.object(c.objectId))
			);
		}
		[paymentCoin] = tx.splitCoins(tx.object(head.objectId), [COST_PER_FLAG]);
	}

	const flagResult = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::merchant::buy_flag`,
		arguments: [paymentCoin],
	});
	tx.transferObjects(Array.isArray(flagResult) ? flagResult : [flagResult], address);

	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
		include: { effects: true, events: true, objectChanges: true },
	});

	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'buy_flag failed');
	}

	const effects = result.Transaction.effects;
	if (!effects?.changedObjects) {
		throw new Error('No effects from transaction');
	}

	// Find the created Flag (Created object owned by sender)
	const created = effects.changedObjects.filter(
		(o) =>
			o.idOperation === 'Created' &&
			o.outputOwner?.$kind === 'AddressOwner' &&
			o.outputOwner.AddressOwner === address
	);
	const flagId = created[0]?.objectId;
	if (!flagId) {
		console.log('Transaction succeeded. Flag object may be in created objects.');
		console.log('Digest:', result.Transaction.digest);
		return;
	}

	// Fetch display for the flag (name is "{source} flag" -> "merchant flag")
	try {
		const { object } = await suiClient.getObject({
			objectId: flagId,
			include: { json: true, display: true },
		});

		if (object?.display?.data) {
			const name = (object.display.data as Record<string, string>)?.name;
			if (name) console.log('Flag:', name);
		}
	} catch {
		// Object may not be immediately visible; digest still indicates success
	}
	console.log('Flag object ID:', flagId);
	console.log('Transaction digest:', result.Transaction.digest);
	console.log('Merchant challenge complete.');
})();

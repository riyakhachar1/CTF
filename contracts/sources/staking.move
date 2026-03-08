
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
const DEPLOYMENT_DIGEST = 'AL133Jj44NV9euC6RreY1gjGHmCMwqfTcuKn6bbrKGqY';
const CLOCK_OBJECT_ID = '0x6';

const MIN_STAKE_HOURS = 168;
const MIN_CLAIM_AMOUNT = 1_000_000_000n; // 1 SUI in MIST
const MS_PER_HOUR = 3_600_000;

// Fast path: merge_receipts adds hours_staked. N receipts × 1 hour each = N hours. Wait 1h, then merge all.
const FAST_PATH_RECEIPT_COUNT = 169;
const FAST_PATH_AMOUNT_PER_RECEIPT = Math.ceil(Number(MIN_CLAIM_AMOUNT) / FAST_PATH_RECEIPT_COUNT);
const _fastPathTotal = BigInt(FAST_PATH_AMOUNT_PER_RECEIPT) * BigInt(FAST_PATH_RECEIPT_COUNT);
const FAST_PATH_TOTAL = _fastPathTotal >= MIN_CLAIM_AMOUNT ? _fastPathTotal : BigInt(FAST_PATH_AMOUNT_PER_RECEIPT + 1) * BigInt(FAST_PATH_RECEIPT_COUNT);

async function getStakingPoolId(): Promise<string> {
	const result = await suiClient.getTransaction({
		digest: DEPLOYMENT_DIGEST,
		include: { effects: true, objectTypes: true },
	});
	const tx = result.$kind === 'Transaction' ? result.Transaction : result.FailedTransaction;
	if (!tx?.effects?.changedObjects) {
		throw new Error('Could not load deployment transaction effects');
	}
	const objectTypes = (tx as { objectTypes?: Record<string, string> }).objectTypes ?? {};
	for (const obj of tx.effects.changedObjects) {
		if (obj.idOperation === 'Created') {
			const type = objectTypes[obj.objectId];
			if (type?.includes('staking::StakingPool')) {
				return obj.objectId;
			}
		}
	}
	for (const [id, type] of Object.entries(objectTypes)) {
		if (type?.includes('staking::StakingPool')) {
			return id;
		}
	}
	// Fallback: fetch each created object and check type
	for (const obj of tx.effects.changedObjects) {
		if (obj.idOperation === 'Created') {
			const { object } = await suiClient.getObject({
				objectId: obj.objectId,
				include: { json: false },
			});
			if (object?.type?.includes('staking::StakingPool')) {
				return obj.objectId;
			}
		}
	}
	throw new Error('StakingPool not found in deployment transaction');
}

async function getChainTimestampMs(): Promise<number> {
	const { object } = await suiClient.getObject({
		objectId: CLOCK_OBJECT_ID,
		include: { json: true },
	});
	if (!object?.json || typeof object.json !== 'object') {
		throw new Error('Could not read Clock object');
	}
	const content = object.json as Record<string, unknown>;
	const ts = content.timestamp_ms;
	if (ts === undefined) {
		throw new Error('Clock object has no timestamp_ms');
	}
	return Number(ts);
}

async function findReceipt(): Promise<{ objectId: string; amount: string; hours_staked: string; last_update_timestamp: string } | null> {
	const address = keypair.getPublicKey().toSuiAddress();
	const { objects } = await suiClient.listOwnedObjects({
		owner: address,
		include: { json: true },
	});
	const receipt = objects.find((obj) => obj.type?.includes('staking::StakeReceipt'));
	if (!receipt) return null;
	const json = receipt.json as Record<string, unknown> | null;
	if (!json) return null;
	return {
		objectId: receipt.objectId,
		amount: String(json.amount ?? 0),
		hours_staked: String(json.hours_staked ?? 0),
		last_update_timestamp: String(json.last_update_timestamp ?? 0),
	};
}

/** All StakeReceipts we own (for fast path: many small receipts) */
async function findAllReceipts(): Promise<{ objectId: string; amount: string; hours_staked: string; last_update_timestamp: string }[]> {
	const address = keypair.getPublicKey().toSuiAddress();
	const { objects } = await suiClient.listOwnedObjects({
		owner: address,
		limit: 256,
		include: { json: true },
	});
	const out: { objectId: string; amount: string; hours_staked: string; last_update_timestamp: string }[] = [];
	for (const obj of objects) {
		if (!obj.type?.includes('staking::StakeReceipt')) continue;
		const json = obj.json as Record<string, unknown> | null;
		if (!json) continue;
		out.push({
			objectId: obj.objectId,
			amount: String(json.amount ?? 0),
			hours_staked: String(json.hours_staked ?? 0),
			last_update_timestamp: String(json.last_update_timestamp ?? 0),
		});
	}
	return out;
}

async function stake(poolId: string): Promise<string> {
	const address = keypair.getPublicKey().toSuiAddress();
	const tx = new Transaction();
	const [coin] = tx.splitCoins(tx.gas, [MIN_CLAIM_AMOUNT]);
	const receipt = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::staking::stake`,
		arguments: [tx.object(poolId), coin, tx.object(CLOCK_OBJECT_ID)],
	});
	tx.transferObjects([receipt], address);

	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
		include: { effects: true, objectTypes: true },
	});

	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'Stake failed');
	}

	const txResult = result.Transaction;
	const effects = txResult.effects;
	if (!effects?.changedObjects) {
		throw new Error('No effects from stake transaction');
	}

	const objectTypes = (txResult as { objectTypes?: Record<string, string> }).objectTypes ?? {};
	for (const obj of effects.changedObjects) {
		if (obj.idOperation === 'Created' && obj.outputOwner?.$kind === 'AddressOwner') {
			const type = objectTypes[obj.objectId];
			if (type?.includes('staking::StakeReceipt')) {
				return obj.objectId;
			}
		}
	}
	throw new Error('StakeReceipt not found in transaction effects');
}

/** Stake many small amounts in one tx (for fast path: wait 1h then merge). Returns created receipt IDs. */
async function stakeMany(poolId: string): Promise<string[]> {
	const address = keypair.getPublicKey().toSuiAddress();
	// Ensure total >= 1 SUI (exact integer: 169 * 5917160 = 999999040 < 1e9, so we need 5917161 per)
	const amountPer = Math.ceil(Number(MIN_CLAIM_AMOUNT) / FAST_PATH_RECEIPT_COUNT);
	const total = BigInt(amountPer) * BigInt(FAST_PATH_RECEIPT_COUNT);
	const amountPerFinal = total >= MIN_CLAIM_AMOUNT ? amountPer : amountPer + 1;
	const amounts = Array<bigint>(FAST_PATH_RECEIPT_COUNT).fill(BigInt(amountPerFinal));

	const tx = new Transaction();
	const coins = tx.splitCoins(tx.gas, amounts);
	const receipts: ReturnType<Transaction['moveCall']>[] = [];
	for (let i = 0; i < FAST_PATH_RECEIPT_COUNT; i++) {
		const rec = tx.moveCall({
			target: `${CTF_PACKAGE_ID}::staking::stake`,
			arguments: [tx.object(poolId), coins[i], tx.object(CLOCK_OBJECT_ID)],
		});
		receipts.push(rec);
	}
	tx.transferObjects(receipts, address);

	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
		include: { effects: true, objectTypes: true },
	});

	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'Stake many failed');
	}

	const txResult = result.Transaction;
	const effects = txResult.effects;
	if (!effects?.changedObjects) throw new Error('No effects from stake many');
	const objectTypes = (txResult as { objectTypes?: Record<string, string> }).objectTypes ?? {};
	const ids: string[] = [];
	for (const obj of effects.changedObjects) {
		if (obj.idOperation === 'Created' && obj.outputOwner?.$kind === 'AddressOwner') {
			const type = objectTypes[obj.objectId];
			if (type?.includes('staking::StakeReceipt')) ids.push(obj.objectId);
		}
	}
	if (ids.length !== FAST_PATH_RECEIPT_COUNT) {
		throw new Error(`Expected ${FAST_PATH_RECEIPT_COUNT} receipts, got ${ids.length}`);
	}
	return ids;
}

/** Update all receipts (add elapsed hours), merge into one, claim flag. Requires receiptIds.length >= MIN_STAKE_HOURS and total amount >= 1 SUI. */
async function updateMergeAndClaim(poolId: string, receiptIds: string[]): Promise<string> {
	const address = keypair.getPublicKey().toSuiAddress();
	const tx = new Transaction();
	const clock = tx.object(CLOCK_OBJECT_ID);
	const pool = tx.object(poolId);

	// Update each receipt so hours_staked reflects elapsed time
	const updated: unknown[] = [];
	for (const id of receiptIds) {
		const rec = tx.moveCall({
			target: `${CTF_PACKAGE_ID}::staking::update_receipt`,
			arguments: [tx.object(id), clock],
		});
		updated.push(rec);
	}

	// Merge pairwise: merge(r0,r1)->m0, merge(m0,r2)->m1, ...
	let merged = updated[0];
	for (let i = 1; i < updated.length; i++) {
		merged = tx.moveCall({
			target: `${CTF_PACKAGE_ID}::staking::merge_receipts`,
			arguments: [merged, updated[i], clock],
		});
	}

	const [flag, coin] = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::staking::claim_flag`,
		arguments: [pool, merged, clock],
	});
	tx.transferObjects([flag, coin], address);

	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
		include: { effects: true },
	});

	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'Update/merge/claim failed');
	}
	return 'Flag claimed successfully.';
}

async function claimFlag(poolId: string, receiptId: string): Promise<string> {
	const address = keypair.getPublicKey().toSuiAddress();
	const tx = new Transaction();
	const [flag, coin] = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::staking::claim_flag`,
		arguments: [tx.object(poolId), tx.object(receiptId), tx.object(CLOCK_OBJECT_ID)],
	});
	tx.transferObjects([flag, coin], address);

	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
		include: { effects: true, events: true },
	});

	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'Claim failed');
	}

	const txResult = result.Transaction;
	const effects = txResult.effects;
	if (!effects?.changedObjects) {
		return 'Flag claimed successfully (check your wallet for the Flag object)';
	}
	for (const obj of effects.changedObjects) {
		if (obj.idOperation === 'Created') {
			console.log('Created object:', obj.objectId);
		}
	}
	return 'Flag claimed successfully.';
}

/** Unstake one receipt and return the SUI coin to sender (so you can re-run with fast path). */
async function unstake(poolId: string, receiptId: string): Promise<void> {
	const address = keypair.getPublicKey().toSuiAddress();
	const tx = new Transaction();
	const coin = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::staking::unstake`,
		arguments: [tx.object(poolId), tx.object(receiptId)],
	});
	tx.transferObjects([coin], address);
	const result = await suiClient.signAndExecuteTransaction({
		transaction: tx,
		signer: keypair,
	});
	if (result.$kind === 'FailedTransaction') {
		throw new Error(result.FailedTransaction.status.error?.message ?? 'Unstake failed');
	}
	console.log('Unstaked. You can run again for the 1-hour fast path.');
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

(async () => {
	const address = keypair.getPublicKey().toSuiAddress();
	console.log('Address:', address);

	const poolId = await getStakingPoolId();
	console.log('StakingPool ID:', poolId);

	const allReceipts = await findAllReceipts();
	const receipt = allReceipts.length === 1 ? allReceipts[0] : null;
	const nowMs = await getChainTimestampMs();

	// Single receipt with enough hours and amount: claim directly
	if (receipt && allReceipts.length === 1) {
		const lastUpdate = Number(receipt.last_update_timestamp);
		const hoursStaked = Number(receipt.hours_staked);
		const hoursPassed = (nowMs - lastUpdate) / MS_PER_HOUR;
		const totalHours = hoursStaked + hoursPassed;
		const amount = BigInt(receipt.amount);

		console.log(`Receipt: ${receipt.objectId}, amount=${receipt.amount}, totalHours≈${totalHours.toFixed(1)}`);

		if (totalHours >= MIN_STAKE_HOURS && amount >= MIN_CLAIM_AMOUNT) {
			console.log('Claiming flag...');
			const msg = await claimFlag(poolId, receipt.objectId);
			console.log(msg);
			return;
		}

		// One receipt not ready: unstake and use fast path (169 stakes, 1h wait) instead of waiting 168h
		// After unstake we get 1 SUI back, so we need: current coins + 1 SUI >= FAST_PATH_TOTAL + gas
		const { objects: coins } = await suiClient.listCoins({ owner: address });
		const totalBalance = coins.reduce((sum, c) => sum + BigInt(c.balance), 0n);
		const balanceAfterUnstake = totalBalance + MIN_CLAIM_AMOUNT; // we get 1 SUI back
		if (balanceAfterUnstake >= FAST_PATH_TOTAL + 50n * 1000n * 1000n) {
			console.log('Unstaking to use fast path (1 hour instead of 168 hours)...');
			await unstake(poolId, receipt.objectId);
			console.log('Fast path: staking 169× ~1/169 SUI each, then 1 hour wait, then claim.');
			const receiptIds = await stakeMany(poolId);
			console.log(`Created ${receiptIds.length} receipts. Waiting 1 hour (polling every minute)...`);
			const startMs = await getChainTimestampMs();
			while ((await getChainTimestampMs()) - startMs < MS_PER_HOUR) {
				await sleep(60 * 1000);
				const left = Math.ceil((MS_PER_HOUR - ((await getChainTimestampMs()) - startMs)) / 60000);
				if (left > 0) console.log(`  ... ${left} minutes left`);
			}
			console.log('1 hour reached. Updating, merging, claiming...');
			console.log(await updateMergeAndClaim(poolId, receiptIds));
			return;
		}

		const waitHours = MIN_STAKE_HOURS - totalHours;
		console.log(`Stake not ready. Need ~${Math.ceil(waitHours)} more hours (${(waitHours * 60).toFixed(0)} minutes).`);
		console.log('Tip: To use the 1-hour fast path, ensure you have ~1 SUI for gas, then run again.');
		console.log('Waiting (polling every 5 minutes)...');
		const pollInterval = 5 * 60 * 1000;
		let remaining = waitHours * MS_PER_HOUR;
		while (remaining > 0) {
			await sleep(Math.min(pollInterval, remaining));
			remaining -= pollInterval;
			const currentMs = await getChainTimestampMs();
			const newHoursPassed = (currentMs - lastUpdate) / MS_PER_HOUR;
			const newTotal = hoursStaked + newHoursPassed;
			if (newTotal >= MIN_STAKE_HOURS) {
				console.log('Stake duration reached. Claiming flag...');
				const msg = await claimFlag(poolId, receipt.objectId);
				console.log(msg);
				return;
			}
			console.log(`  ... ${(MIN_STAKE_HOURS - newTotal).toFixed(1)} hours left`);
		}
		return;
	}

	// Fast path: many small receipts. After 1 hour we can update, merge, and claim.
	if (allReceipts.length >= MIN_STAKE_HOURS) {
		const totalAmount = allReceipts.reduce((s, r) => s + BigInt(r.amount), 0n);
		const oldestUpdate = Math.min(...allReceipts.map((r) => Number(r.last_update_timestamp)));
		const hoursPassed = (nowMs - oldestUpdate) / MS_PER_HOUR;

		if (totalAmount >= MIN_CLAIM_AMOUNT && hoursPassed >= 1) {
			console.log(`${allReceipts.length} receipts, ${hoursPassed.toFixed(1)}h passed. Updating, merging, claiming...`);
			const msg = await updateMergeAndClaim(poolId, allReceipts.map((r) => r.objectId));
			console.log(msg);
			return;
		}

		const waitMins = Math.ceil((1 - hoursPassed) * 60);
		console.log(`Fast path: ${allReceipts.length} receipts. Need ~${Math.max(0, waitMins)} more minutes, then will merge & claim.`);
		const pollInterval = 1 * 60 * 1000; // 1 min
		while ((await getChainTimestampMs()) - oldestUpdate < MS_PER_HOUR) {
			await sleep(pollInterval);
		}
		console.log('1 hour reached. Updating, merging, claiming...');
		const msg = await updateMergeAndClaim(poolId, allReceipts.map((r) => r.objectId));
		console.log(msg);
		return;
	}

	// No receipts or wrong count: start fast path (169 stakes, wait 1h, merge & claim)
	const { objects: coins } = await suiClient.listCoins({ owner: address });
	const totalBalance = coins.reduce((sum, c) => sum + BigInt(c.balance), 0n);
	if (totalBalance < FAST_PATH_TOTAL + 50n * 1000n * 1000n) {
		throw new Error(
			`Need at least ${Number(FAST_PATH_TOTAL) / 1e9} SUI + gas for fast path (${FAST_PATH_RECEIPT_COUNT} stakes). Balance: ${totalBalance}`
		);
	}

	console.log(`Fast path: staking ${FAST_PATH_RECEIPT_COUNT}× ~${Math.ceil(Number(MIN_CLAIM_AMOUNT) / FAST_PATH_RECEIPT_COUNT)} MIST (~1 SUI total), then 1 hour wait, then claim.`);
	console.log('Staking...');
	const receiptIds = await stakeMany(poolId);
	console.log(`Created ${receiptIds.length} receipts. Waiting 1 hour (polling every minute)...`);

	const startMs = await getChainTimestampMs();
	const oneHourMs = MS_PER_HOUR;
	while (true) {
		await sleep(60 * 1000);
		const elapsed = (await getChainTimestampMs()) - startMs;
		if (elapsed >= oneHourMs) break;
		console.log(`  ... ${Math.ceil((oneHourMs - elapsed) / 60000)} minutes left`);
	}

	console.log('1 hour reached. Updating, merging, claiming...');
	const msg = await updateMergeAndClaim(poolId, receiptIds);
	console.log(msg);
})();

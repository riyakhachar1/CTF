
import 'dotenv/config';
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import keyPairJson from '../keypair.json' with { type: 'json' };

/**
 * Sabotage Arena (PvP): Register, build shield to 12, sabotage others, claim flag.
 *
 * Optional .env: ARENA_ID, OPPONENTS (comma-separated addresses).
 * If ARENA_ID is not set, the script tries to discover the Arena from the package deployment.
 */
const keypair = Ed25519Keypair.fromSecretKey(keyPairJson.privateKey);
const suiClient = new SuiGrpcClient({
	network: 'testnet',
	baseUrl: 'https://fullnode.testnet.sui.io:443',
});

const CTF_PACKAGE_ID = '0xd56e5075ba297f9e37085a37bb0abba69fabdf9987f8f4a6086a3693d88efbfd';
const DEPLOYMENT_DIGEST = 'AL133Jj44NV9euC6RreY1gjGHmCMwqfTcuKn6bbrKGqY'; // package publish tx (same as staking)
const CLOCK_OBJECT_ID = '0x6';
const SHIELD_THRESHOLD = 12;
const COOLDOWN_MS = 600_000; // 10 minutes

const ARENA_ID = process.env.ARENA_ID ?? '';
const OPPONENTS_CSV = process.env.OPPONENTS ?? '';

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatDuration(ms: number): string {
	if (ms >= 3600_000) {
		const h = Math.floor(ms / 3600_000);
		const m = Math.round((ms % 3600_000) / 60_000);
		return m > 0 ? `${h}h ${m}m` : `${h}h`;
	}
	const m = Math.floor(ms / 60_000);
	const s = Math.round((ms % 60_000) / 1000);
	return s > 0 ? `${m} min ${s}s` : `${m} min`;
}

/** Sleep for ms, updating a single line with countdown every intervalMs. */
async function sleepWithCountdown(
	ms: number,
	options: { prefix?: string; intervalMs?: number } = {}
): Promise<void> {
	const { prefix = 'Cooldown', intervalMs = 30_000 } = options;
	const start = Date.now();
	let lastPrinted = '';
	const update = () => {
		const elapsed = Date.now() - start;
		const left = Math.max(0, ms - elapsed);
		const line = left > 0 ? `${prefix}: ${formatDuration(left)} remaining` : `${prefix}: done`;
		if (line !== lastPrinted) {
			process.stdout.write(`\r${line.padEnd(60)}`);
			lastPrinted = line;
		}
	};
	update();
	const t = setInterval(update, Math.min(intervalMs, 5000));
	await sleep(ms);
	clearInterval(t);
	process.stdout.write('\r' + ' '.repeat(60) + '\r');
}

const ATTACK_POLL_MS = 30_000; // check for attacks every 30 sec during cooldown

/**
 * Wait for waitMs, updating countdown; poll on-chain shield every ATTACK_POLL_MS.
 * If shield drops below expectedShield, return immediately with { attacked: true, newShield }.
 */
async function sleepWithAttackCheck(
	arenaId: string,
	sender: string,
	expectedShield: number,
	waitMs: number,
	options: { prefix?: string } = {}
): Promise<{ attacked: false } | { attacked: true; newShield: number }> {
	const { prefix = 'Cooldown' } = options;
	const start = Date.now();
	let lastPrinted = '';
	while (true) {
		const elapsed = Date.now() - start;
		const remaining = Math.max(0, waitMs - elapsed);
		// Check for attack at start of each poll interval
		const onChain = await getOnChainShield(arenaId, sender);
		if (onChain !== null && onChain < expectedShield) {
			process.stdout.write('\r' + ' '.repeat(60) + '\r');
			return { attacked: true, newShield: onChain };
		}
		if (remaining <= 0) {
			process.stdout.write('\r' + ' '.repeat(60) + '\r');
			return { attacked: false };
		}
		const chunkMs = Math.min(ATTACK_POLL_MS, remaining);
		const chunkStart = Date.now();
		while (Date.now() - chunkStart < chunkMs) {
			const elapsedInChunk = Date.now() - chunkStart;
			const totalRemaining = Math.max(0, remaining - elapsedInChunk);
			const line = `${prefix}: ${formatDuration(totalRemaining)} remaining`;
			if (line !== lastPrinted) {
				process.stdout.write(`\r${line.padEnd(60)}`);
				lastPrinted = line;
			}
			await sleep(5000);
		}
	}
}

function progressBar(current: number, total: number, width = 20): string {
	const filled = Math.round((current / total) * width);
	const bar = '█'.repeat(filled) + '░'.repeat(width - filled);
	return `[${bar}] ${current}/${total}`;
}

/** Encode Sui address as 32-byte BCS for dynamic field key. Handles 0x-prefix and 40- or 64-char hex. */
function addressToBcs(addr: string): Uint8Array {
	const hex = addr.replace(/^0x/i, '');
	const padded = hex.length >= 64 ? hex.slice(0, 64) : hex.padStart(64, '0');
	if (padded.length !== 64) throw new Error('Invalid address length');
	const bytes = new Uint8Array(32);
	for (let i = 0; i < 32; i++) bytes[i] = parseInt(padded.slice(i * 2, i * 2 + 2), 16);
	return bytes;
}

function readU64LE(bytes: Uint8Array, offset: number): number {
	let n = 0;
	for (let i = 0; i < 8; i++) n += bytes[offset + i]! * 2 ** (i * 8);
	return n;
}

async function getPlayersTableId(arenaId: string): Promise<string | null> {
	try {
		const { object } = await suiClient.getObject({
			objectId: arenaId,
			include: { json: true },
		});
		if (!object?.json || typeof object.json !== 'object') return null;
		const arena = object.json as Record<string, unknown>;
		const players = arena.players as { id?: string } | undefined;
		if (players && typeof players.id === 'string') return players.id;
	} catch {
		// ignore
	}
	return null;
}

/** PlayerState BCS: shield (u64) at 0, last_action_ms (u64) at 8. */
async function getPlayerStateFromChain(
	arenaId: string,
	player: string
): Promise<{ shield: number; last_action_ms: number } | null> {
	const tableId = await getPlayersTableId(arenaId);
	if (!tableId) return null;
	try {
		const nameBcs = addressToBcs(player);
		const res = await suiClient.getDynamicField({
			parentId: tableId,
			name: { type: 'address', bcs: nameBcs },
		});
		const value = res.dynamicField?.value as { bcs?: Uint8Array } | undefined;
		if (!value?.bcs || value.bcs.length < 16) return null;
		const bcs = value.bcs;
		return {
			shield: readU64LE(bcs, 0),
			last_action_ms: readU64LE(bcs, 8),
		};
	} catch {
		return null;
	}
}

async function getOnChainShield(arenaId: string, player: string): Promise<number | null> {
	// 1) Try Table + getDynamicField (reliable on Sui)
	const tableId = await getPlayersTableId(arenaId);
	if (tableId) {
		try {
			const nameBcs = addressToBcs(player);
			const res = await suiClient.getDynamicField({
				parentId: tableId,
				name: { type: 'address', bcs: nameBcs },
			});
			const value = res.dynamicField?.value as { bcs?: Uint8Array } | undefined;
			if (value?.bcs && value.bcs.length >= 8) {
				return readU64LE(value.bcs, 0);
			}
		} catch {
			// fall through to JSON fallback
		}
	}
	// 2) Fallback: JSON from getObject (Table often not expanded)
	try {
		const { object } = await suiClient.getObject({
			objectId: arenaId,
			include: { json: true },
		});
		if (!object?.json || typeof object.json !== 'object') return null;
		const arena = object.json as Record<string, unknown>;
		const players = arena.players as Record<string, unknown> | undefined;
		if (!players) return null;
		const state = (players as Record<string, { shield?: number }>)[player];
		if (state?.shield !== undefined) return Number(state.shield);
	} catch {
		// ignore
	}
	return null;
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

/** Wait until chain says we're off cooldown (using last_action_ms + COOLDOWN_MS). */
async function waitForCooldown(arenaId: string, player: string): Promise<void> {
	const state = await getPlayerStateFromChain(arenaId, player);
	if (!state) {
		console.log('  Could not read cooldown from chain, waiting full cooldown...');
		await sleepWithCountdown(COOLDOWN_MS, { prefix: 'Cooldown', intervalMs: 30_000 });
		return;
	}
	const chainNow = await getChainTimestampMs();
	const nextActionMs = state.last_action_ms + COOLDOWN_MS;
	const remainingMs = nextActionMs - chainNow;
	if (remainingMs <= 0) return;
	console.log(`  Waiting for cooldown: ${formatDuration(remainingMs)} remaining...`);
	await sleepWithCountdown(remainingMs, { prefix: 'Cooldown', intervalMs: 30_000 });
}

async function findArenaIdFromDeployment(): Promise<string | null> {
	try {
		const result = await suiClient.getTransaction({
			digest: DEPLOYMENT_DIGEST,
			include: { effects: true, objectTypes: true },
		});
		const tx = result.$kind === 'Transaction' ? result.Transaction : result.FailedTransaction;
		if (!tx?.effects?.changedObjects) return null;
		const objectTypes = (tx as { objectTypes?: Record<string, string> }).objectTypes ?? {};
		for (const obj of tx.effects.changedObjects) {
			if (obj.idOperation === 'Created') {
				const type = objectTypes[obj.objectId];
				if (type?.includes('sabotage_arena::Arena')) {
					return obj.objectId;
				}
			}
		}
		for (const [id, type] of Object.entries(objectTypes)) {
			if (type?.includes('sabotage_arena::Arena')) return id;
		}
		for (const obj of tx.effects.changedObjects) {
			if (obj.idOperation === 'Created') {
				const { object } = await suiClient.getObject({
					objectId: obj.objectId,
					include: { json: false },
				});
				if (object?.type?.includes('sabotage_arena::Arena')) {
					return obj.objectId;
				}
			}
		}
	} catch {
		// ignore
	}
	return null;
}

async function getArenaId(): Promise<string> {
	if (ARENA_ID.trim()) return ARENA_ID.trim();
	const discovered = await findArenaIdFromDeployment();
	if (discovered) {
		console.log('Discovered Arena ID from deployment tx:', discovered);
		return discovered;
	}
	throw new Error(
		'Could not find Arena. Set ARENA_ID in .env or env to the shared Arena object ID (from CTF or explorer).'
	);
}

function getOpponents(selfAddress: string): string[] {
	if (!OPPONENTS_CSV.trim()) return [];
	return OPPONENTS_CSV.split(',')
		.map((s) => s.trim())
		.filter((s) => s.length > 0 && s !== selfAddress);
}

// Contract abort codes
const ABORT_ALREADY_REGISTERED = 0;
const ABORT_NOT_REGISTERED = 1;
const ABORT_COOLDOWN_ACTIVE = 2;
const ABORT_SHIELD_BELOW_THRESHOLD = 3;
const ABORT_NO_FLAGS_REMAINING = 4;
const ABORT_ARENA_CLOSED = 5;

function getAbortCode(err: unknown): number | null {
	const msg = err instanceof Error ? err.message : String(err);
	const match = msg.match(/abort code:\s*(\d+)/);
	if (match) return Number(match[1]);
	const execErr = (err as { executionError?: { MoveAbort?: { abortCode?: string } } })?.executionError;
	if (execErr?.MoveAbort?.abortCode != null) return Number(execErr.MoveAbort.abortCode);
	return null;
}

async function register(arenaId: string): Promise<boolean> {
	const tx = new Transaction();
	tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::register`,
		arguments: [tx.object(arenaId), tx.object(CLOCK_OBJECT_ID)],
	});

	try {
		const result = await suiClient.signAndExecuteTransaction({
			transaction: tx,
			signer: keypair,
			include: { effects: true },
		});
		if (result.$kind === 'FailedTransaction') {
			throw new Error(result.FailedTransaction.status.error?.message ?? 'Register failed');
		}
		return true;
	} catch (e) {
		if (getAbortCode(e) === ABORT_ALREADY_REGISTERED) return false;
		throw e;
	}
}

async function build(arenaId: string): Promise<void> {
	const tx = new Transaction();
	tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::build`,
		arguments: [tx.object(arenaId), tx.object(CLOCK_OBJECT_ID)],
	});

	try {
		const result = await suiClient.signAndExecuteTransaction({
			transaction: tx,
			signer: keypair,
			include: { effects: true },
		});
		if (result.$kind === 'FailedTransaction') {
			throw new Error(result.FailedTransaction.status.error?.message ?? 'Build failed');
		}
	} catch (e) {
		if (getAbortCode(e) === ABORT_COOLDOWN_ACTIVE) throw new Error('COOLDOWN_ACTIVE');
		throw e;
	}
}

async function attack(arenaId: string, targetAddress: string): Promise<void> {
	const tx = new Transaction();
	tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::attack`,
		arguments: [
			tx.object(arenaId),
			tx.pure.address(targetAddress),
			tx.object(CLOCK_OBJECT_ID),
		],
	});

	try {
		const result = await suiClient.signAndExecuteTransaction({
			transaction: tx,
			signer: keypair,
			include: { effects: true },
		});
		if (result.$kind === 'FailedTransaction') {
			throw new Error(result.FailedTransaction.status.error?.message ?? 'Attack failed');
		}
	} catch (e) {
		if (getAbortCode(e) === ABORT_COOLDOWN_ACTIVE) throw new Error('COOLDOWN_ACTIVE');
		throw e;
	}
}

async function claimFlag(arenaId: string): Promise<void> {
	const tx = new Transaction();
	const flagResult = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::claim_flag`,
		arguments: [tx.object(arenaId), tx.object(CLOCK_OBJECT_ID)],
	});
	const sender = keypair.getPublicKey().toSuiAddress();
	tx.transferObjects(Array.isArray(flagResult) ? flagResult : [flagResult], sender);

	try {
		const result = await suiClient.signAndExecuteTransaction({
			transaction: tx,
			signer: keypair,
			include: { effects: true },
		});
		if (result.$kind === 'FailedTransaction') {
			throw new Error(result.FailedTransaction.status.error?.message ?? 'Claim flag failed');
		}
	} catch (e) {
		const code = getAbortCode(e);
		if (code === ABORT_SHIELD_BELOW_THRESHOLD) throw new Error('SHIELD_BELOW_THRESHOLD');
		if (code === ABORT_NO_FLAGS_REMAINING) throw new Error('NO_FLAGS_REMAINING');
		throw e;
	}
}

/** One tx: build then claim_flag. Use when shield === 11 to claim as soon as possible without sitting at 12. */
async function buildAndClaimFlag(arenaId: string): Promise<void> {
	const sender = keypair.getPublicKey().toSuiAddress();
	const tx = new Transaction();
	tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::build`,
		arguments: [tx.object(arenaId), tx.object(CLOCK_OBJECT_ID)],
	});
	const flagResult = tx.moveCall({
		target: `${CTF_PACKAGE_ID}::sabotage_arena::claim_flag`,
		arguments: [tx.object(arenaId), tx.object(CLOCK_OBJECT_ID)],
	});
	tx.transferObjects(Array.isArray(flagResult) ? flagResult : [flagResult], sender);

	try {
		const result = await suiClient.signAndExecuteTransaction({
			transaction: tx,
			signer: keypair,
			include: { effects: true },
		});
		if (result.$kind === 'FailedTransaction') {
			throw new Error(result.FailedTransaction.status.error?.message ?? 'Build+claim failed');
		}
	} catch (e) {
		const code = getAbortCode(e);
		if (code === ABORT_COOLDOWN_ACTIVE) throw new Error('COOLDOWN_ACTIVE');
		if (code === ABORT_SHIELD_BELOW_THRESHOLD) throw new Error('SHIELD_BELOW_THRESHOLD');
		if (code === ABORT_NO_FLAGS_REMAINING) throw new Error('NO_FLAGS_REMAINING');
		throw e;
	}
}

(async () => {
	const sender = keypair.getPublicKey().toSuiAddress();
	const arenaId = await getArenaId();
	const opponents = getOpponents(sender);

	console.log('Address:', sender);
	console.log('Arena:', arenaId);
	console.log(
		'Opponents to sabotage:',
		opponents.length ? opponents : '(none set; set OPPONENTS env for comma-separated addresses)'
	);
	console.log('Shield threshold:', SHIELD_THRESHOLD, '| Cooldown:', COOLDOWN_MS / 60_000, 'min');
	console.log('');

	// 1) Register if needed
	const newlyRegistered = await register(arenaId);
	console.log(newlyRegistered ? 'Registered in the arena.' : 'Already registered.');

	const state = await getPlayerStateFromChain(arenaId, sender);
	let shield: number;
	if (state) {
		shield = state.shield;
		console.log(`Shield at start: ${shield} (from chain)`);
		const chainNow = await getChainTimestampMs();
		const nextActionMs = state.last_action_ms + COOLDOWN_MS;
		const remainingMs = nextActionMs - chainNow;
		if (remainingMs > 0) {
			console.log(`Cooldown: ${formatDuration(remainingMs)} remaining`);
		} else {
			console.log('Cooldown: ready');
		}
	} else {
		const onChainShield = await getOnChainShield(arenaId, sender);
		shield = onChainShield ?? 0;
		console.log(`Shield at start: ${shield}${onChainShield !== null ? ' (from chain)' : ' (could not read chain; assuming 0)'}`);
		console.log('Cooldown: unknown (could not read chain)');
	}
	let actionIndex = 0;
	let nextOpponentIndex = 0;
	let claimedInThisRun = false;

	// 2) Loop: wait cooldown -> build or attack -> until shield >= 12 then claim
	while (true) {
		while (shield < SHIELD_THRESHOLD) {
			// Detect if we were attacked since last action (on-chain shield dropped)
			const currentOnChainShield = await getOnChainShield(arenaId, sender);
			if (currentOnChainShield !== null && currentOnChainShield < shield) {
				console.log(`\n  ⚠ You were attacked! Shield dropped from ${shield} to ${currentOnChainShield}.\n`);
				shield = currentOnChainShield;
			}

			const shouldSabotage =
				opponents.length > 0 &&
				shield < SHIELD_THRESHOLD &&
				shield !== SHIELD_THRESHOLD - 1 && // when 11, always build+claim instead of attacking
				actionIndex > 0 &&
				actionIndex % 2 === 0;

			// Only wait cooldown after we've already performed an action (contract uses last_action_ms; new players have 0)
			if (actionIndex > 0) {
				const buildsLeft = SHIELD_THRESHOLD - shield;
				const etaMs = buildsLeft * COOLDOWN_MS; // min time (builds only)
				console.log('');
				console.log(
					`  ${progressBar(shield, SHIELD_THRESHOLD)}  |  ~${formatDuration(etaMs)} until ready to claim`
				);
				// Wait remaining cooldown from chain, and poll for attacks every 30s
				const stateForWait = await getPlayerStateFromChain(arenaId, sender);
				const remainingCooldownMs =
					stateForWait != null
						? Math.max(0, stateForWait.last_action_ms + COOLDOWN_MS - (await getChainTimestampMs()))
						: COOLDOWN_MS;
				if (remainingCooldownMs > 0) {
					console.log(`  Waiting ${formatDuration(remainingCooldownMs)} cooldown (checking for attacks every 30s)...`);
					const waitResult = await sleepWithAttackCheck(
						arenaId,
						sender,
						shield,
						remainingCooldownMs,
						{ prefix: 'Cooldown' }
					);
					if (waitResult.attacked) {
						console.log(`\n  ⚠ You were attacked during cooldown! Shield dropped from ${shield} to ${waitResult.newShield}.\n`);
						shield = waitResult.newShield;
						continue;
					}
				}
				console.log('  Cooldown complete.');
			}

			// Prefer building to reach threshold. Every 2nd action we sabotage one opponent if we have any.
			if (actionIndex === 0 && shield < SHIELD_THRESHOLD) {
				console.log(`  ${progressBar(shield, SHIELD_THRESHOLD)}  |  next: build`);
			}
			if (shouldSabotage) {
				const target = opponents[nextOpponentIndex % opponents.length];
				nextOpponentIndex++;
				console.log(`Attacking opponent ${target.slice(0, 10)}...`);
				let attacked = false;
				while (!attacked) {
					try {
						process.stdout.write('  Sending attack tx... ');
						await attack(arenaId, target);
						attacked = true;
						console.log('OK');
					} catch (e) {
						const msg = e instanceof Error ? e.message : String(e);
						if (msg === 'COOLDOWN_ACTIVE') {
							await waitForCooldown(arenaId, sender);
						} else {
							console.warn('Attack failed:', msg);
							break;
						}
					}
				}
			} else {
				console.log('Building shield...');
				let built = false;
				while (!built) {
					try {
						if (shield === SHIELD_THRESHOLD - 1) {
							// Shield 11: build+claim in one tx so we never sit at 12 and get attacked
							process.stdout.write('  Build+claim in one tx (shield 11→12)... ');
							await buildAndClaimFlag(arenaId);
							claimedInThisRun = true;
							shield = SHIELD_THRESHOLD;
							built = true;
							console.log('OK → flag claimed.');
						} else {
							process.stdout.write('  Sending build tx... ');
							await build(arenaId);
							shield++;
							built = true;
							console.log(`OK → ${progressBar(shield, SHIELD_THRESHOLD)}`);
						}
					} catch (e) {
						const msg = e instanceof Error ? e.message : String(e);
						if (msg === 'COOLDOWN_ACTIVE') {
							await waitForCooldown(arenaId, sender);
						} else {
							throw e;
						}
					}
				}
			}
			actionIndex++;
		}

		if (claimedInThisRun) break;

		// Before claiming, verify we weren't attacked after last build
		const onChainBeforeClaim = await getOnChainShield(arenaId, sender);
		if (onChainBeforeClaim !== null && onChainBeforeClaim < SHIELD_THRESHOLD) {
			console.log(`\n  ⚠ You were attacked before claiming! Shield dropped to ${onChainBeforeClaim}. Continuing to build...\n`);
			shield = onChainBeforeClaim;
			continue;
		}
		break;
	}

	// 3) Claim flag (skip if we already claimed via build+claim at shield 11)
	if (!claimedInThisRun) {
		console.log('Shield threshold reached. Claiming flag...');
		await claimFlag(arenaId);
	}
	console.log('Flag claimed successfully.');
})();

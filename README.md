# Sui CTF

Welcome to the Sui Capture the Flag challenge! This CTF is designed to test and improve your understanding of Sui Move smart contracts, the Sui object model, and Programmable Transaction Blocks (PTBs).

## Table of Contents

- [Sui CTF](#sui-ctf)
  - [Table of Contents](#table-of-contents)
- [Getting Started](#getting-started)
  - [Create Your Own Copy of This Repo](#create-your-own-copy-of-this-repo)
  - [Environment Setup](#environment-setup)
    - [Prerequisites](#prerequisites)
    - [Setup Instructions](#setup-instructions)
  - [Getting testing credits](#getting-testing-credits)
- [Challenges](#challenges)
    - [Structure](#structure)
  - [Moving Window Challenge](#moving-window-challenge)
    - [Instructions](#instructions)
  - [Merchant Challenge](#merchant-challenge)
    - [Instructions](#instructions-1)
  - [Lootboxes Challenge](#lootboxes-challenge)
    - [Instructions](#instructions-2)
    - [Hints](#hints)
  - [Staking Challenge](#staking-challenge)
    - [Instructions](#instructions-3)
  - [Sabotage Arena Challenge (PvP)](#sabotage-arena-challenge-pvp)
    - [Instructions](#instructions-4)

# Getting Started

## Create Your Own Copy of This Repo

> **Important:** Do NOT clone or fork this repository directly. Instead, create a **template copy** so you have your own independent repo to work in.

1. At the top of this repository's GitHub page, click the **"Use this template"** button (top-right corner).
2. Select **"Create a new repository"**.
3. Give your repo a name, and **make sure it is set to Public**.
4. Click **"Create repository"**.
5. Clone your newly created repository to your local machine:

```bash
git clone <your-new-repo-url>
cd <your-new-repo-name>
```

## Environment Setup

Now that you have your own copy, set up your environment and create a keypair for interacting with the Sui blockchain.

### Prerequisites

- Node.js (v18 or higher recommended)
- pnpm package manager

### Setup Instructions

1. Navigate to the `scripts` directory:

```bash
cd scripts
```

1. Install dependencies:

```bash
pnpm install
```

1. Generate and fund a new keypair:

```bash
pnpm init-keypair
```

This will generate a new Ed25519 keypair and save it to `keypair.json` in the scripts directory. **Make sure not to use this keypair in any production environments.**

## Getting testing credits

If you are at a hackathon or workshop event, ask your Sui rep for a dedicated faucet (or check the track details). Otherwise, use the [Official Sui faucet](https://faucet.sui.io/).

You can view your account and balance on the Sui Explorer at:

```
https://suiscan.xyz/testnet/account/{your-address}
```

# Challenges

**Deployed Contract Address:** `0xd56e5075ba297f9e37085a37bb0abba69fabdf9987f8f4a6086a3693d88efbfd`

**Transaction Digest:** `AL133Jj44NV9euC6RreY1gjGHmCMwqfTcuKn6bbrKGqY`

All challenges are Move modules within the single `ctf` package located in the `contracts/` directory.

All challenges are independent of each other and can be done in any order!

### Structure

```
contracts/
├── Move.toml          # Package: ctf
└── sources/
    ├── flag.move      # Base flag module
    └── ...            # Challenge modules will be added here
```

## Moving Window Challenge

Extract the flag during the moving window.

### Instructions

1. Examine the `[moving_window.move](./contracts/sources/moving_window.move)` contract carefully.
2. Determine when the window is open.
3. Implement your solution in `[scripts/src/moving_window.ts](./scripts/src/moving_window.ts)`.
4. Run your script with `pnpm moving-window` to extract the flag.

## Merchant Challenge

Buy a flag using USDC tokens.

### Instructions

1. Examine the `[merchant.move](./contracts/sources/merchant.move)` contract carefully.
2. Acquire USDC tokens on testnet.
3. Implement your solution in `[scripts/src/merchant.ts](./scripts/src/merchant.ts)`.
4. Run your script with `pnpm merchant` to extract the flag.

## Lootboxes Challenge

Open lootboxes until you get a flag (1 in 100,000 chance!).

### Instructions

1. Examine the `[lootboxes.move](./contracts/sources/lootboxes.move)` contract carefully.
2. Notice the odds of winning: 1 in 100,000. Brute forcing would cost hundreds of dollars in gas fees!
3. You'll need to deploy your own Move contract to solve this efficiently.
4. Create your exploit contract in the `[exploit/](./exploit/)` directory.
5. Deploy your contract and call it repeatedly until you win.

### Hints

Read the [Sui randomness documentation](https://docs.sui.io/guides/developer/on-chain-primitives/randomness-onchain), especially:

- The section on **"Use (non-public) entry functions"**
- Why `#[allow(lint(public_random))]` exists and what it allows
- What **"composition attacks"** means in this context

**Key questions to consider:**

- What's the difference between a `public` function and an `entry` function?
- When a function is `public`, what can other Move modules do with it?
- How can you make a transaction abort conditionally to avoid paying gas for failed attempts?
- Look at the `extract_flag()` function - what happens when you call it on a MaybeFlag without a flag?

**Additional help:**

- If you're getting `PostRandomCommandRestrictions` errors, remember that PTBs with randomness have restrictions on what commands can follow the random call.

## Staking Challenge

Stake SUI tokens to earn the right to claim a flag.

### Instructions

1. Examine the `[staking.move](./contracts/sources/staking.move)` contract carefully.
2. Understand the staking requirements: you must stake a minimum of 1 SUI for at least 1 week (168 hours).
3. Implement your solution in `[scripts/src/staking.ts](./scripts/src/staking.ts)`.
4. Run your script with `pnpm staking` to extract the flag.

## Sabotage Arena Challenge (PvP)

Compete against other players to build your shield to the threshold and claim a flag — while sabotaging others along the way.

### Instructions

1. Examine the `[sabotage_arena.move](./contracts/sources/sabotage_arena.move)` contract carefully.
2. Register, build your shield, and attack opponents using `[scripts/src/sabotage_arena.ts](./scripts/src/sabotage_arena.ts)`.
3. Implement your solution to reach the shield threshold and claim a flag.

---

**Note**: This CTF is for educational purposes only. The keypair generated is for testnet use only and should never be used on mainnet or with real assets.
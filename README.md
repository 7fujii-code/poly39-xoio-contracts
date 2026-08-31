# Poly39 & XOIO — On-Chain Lottery & Hash Game Contracts

Decentralized lottery and instant hash-betting games running entirely on **Polygon** smart contracts. Fully open-source, verifiable, and auditable on-chain.

## 🎰 Poly39 — On-Chain Lottery

A fully decentralized 5-number lottery on Polygon.

- **Contract:** `Poly39V6_Polygon`
- **Mainnet address:** [`0x89072cD5859EfeDad2CF947A27622f126439f3C2`](https://polygonscan.com/address/0x89072cD5859EfeDad2CF947A27622f126439f3C2)
- **Site:** https://poly39.io

### How it works

- Each round lasts **120 minutes** (90 min betting → 5 min draw buffer → 25 min distribution).
- Players pick **5 numbers**; tickets are 5 USDT each.
- Winning numbers are generated from the **Polygon block hash** at draw time — fully random and immutable, verifiable by anyone.
- Prizes are distributed **automatically by the contract** to winners' wallets — no manual claims.
- **1% management fee** per round, 60% of which is shared with equity partners.

### Prize structure

| Prize | Match | Share |
|---|---|---|
| 1st | 5/5 | 60% of prize pool |
| 2nd | 4/5 | 10% of prize pool |
| 3rd | 3/5 | Fixed 250 USDT |
| 4th | 2/5 | Fixed 10 USDT |

### Verification

Every draw emits a `DrawExecuted(roundId, uint256[5] winningNumbers)` event — anyone can verify the 5 winning numbers directly on [Polygonscan](https://polygonscan.com/address/0x89072cD5859EfeDad2CF947A27622f126439f3C2#events).

## ⚡ XOIO — On-Chain Hash Game

Instant betting on the last hexadecimal character of a **block-hash-derived** random value.

- **Contracts:** `XOIOV2` → `XOIOV3` → `XOIOV4` (latest)
- **Mainnet address (V4):** `0x932B485e0cc57Ca23Ca735984f7846d6A3c638E0`
- **Site:** https://xoio.io

### How it works

- The contract generates a random hash; the **last character** (0–9 or a–f, 16 outcomes) determines the result.
- Three bet types: **EVEN/ODD (×2)**, **DIGIT 0–9 (×15)**, **LETTER A–F (×15)**.
- Max 50 USDT per bet, up to 20 bets per transaction.
- Result is emitted as a `GameResult` event and verifiable on Polygonscan.

## 📁 Repository structure

```
contracts/
├── poly39/
│   └── Poly39V6_Polygon.sol      # Lottery contract (mainnet)
└── xoio/
    ├── XOIOV2.sol                # Hash game v2
    ├── XOIOV3.sol                # Hash game v3
    ├── XOIOV4.sol                # Hash game v4 (mainnet)
    ├── XOIOV2_flattened.sol
    ├── XOIOV3_flattened.sol
    └── XOIOV4_flattened.sol
```

## 🔒 Security

- Both contracts are **verified on Polygonscan** — source code is public and auditable.
- Randomness comes from **on-chain block hashes** — provably fair, no black boxes.
- All funds are held in the smart contracts; payouts execute automatically.

## 📬 Contact

- **Email:** [admin@poly39.io](mailto:admin@poly39.io)
- **X / Twitter:** [@poly39io](https://x.com/poly39io)
- **Poly39:** https://poly39.io
- **XOIO:** https://xoio.io

Interested in the Equity Partner Program or partnerships? Reach out anytime.

## ⚠️ Disclaimer

This repository contains smart contract source code for transparency and audit purposes. Nothing here is financial advice. DeFi and on-chain gaming involve risk — always do your own research.

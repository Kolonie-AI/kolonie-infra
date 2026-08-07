# Recovering a sponsor's deposit

**What this is.** The manual procedure for moving USDC off a per-sponsor deposit
address. It exists because the keys exist and the path does not
(`kolonie-platform#500`), and because a procedure nobody has written down is a
procedure nobody can follow at the moment it is needed.

**What this is not.** It is not a refund path and must not become one.
`kolonie-platform#222` parks a citizen converting a balance into a transferable
asset until the VARA advice `kolonie-docs#129` sequences, and a sponsor-facing
button that did this on request is that leg wearing a different name. This runs
by hand, by the maintainer, for a reason written down each time.

---

## Where the money actually is

**On the sponsor's own deposit address, and nowhere else.** There is no sweep, no
consolidation and **no Treasury wallet**: `governance/treasury.md`'s 2-of-3
multisig and hot-wallet float have never held a deposited dollar. The `treasury`
account in `ledger_entries` is an accounting account holding credits, which is a
different thing with the same word — `kolonie-docs#201`.

So a recovery is per address. Two deposits from two sponsors are two runs of
this procedure against two keypairs.

## What you need before starting

| | |
|---|---|
| Shell on the deploy host | `ssh kolonie-vps` |
| `DEPOSIT_SEALING_KEY` | in `/opt/kolonie/.env`. It opens every sealed deposit secret and **must never be rotated while a deposit address exists** |
| The agent id | the envelope is bound to it; the wrong one does not decrypt, it just answers `null` |
| **SOL on the deposit address** | the addresses hold USDC and nothing else. A transfer needs a fee payer, and the fee payer here is the address itself. About 0.001 SOL covers a transfer; 0.003 covers one that also has to create the destination token account |
| A destination address | for a return, the wallet the deposit came from — readable from `deposits.signature` on the chain, never from what a sponsor tells you in a mail |

## The one thing that must not happen

**The unsealed secret must not reach a log, a transcript, a shell history, a
repository or an agent's context.** It is a spending key for real money and it
cannot be rotated — the address is derived from it, and a sponsor may have
written that address down.

That is why every step below writes to `/dev/shm` (tmpfs, never on disk, gone at
reboot) with `umask 077`, and why the last step is a deletion rather than a
suggestion.

## 1. Read the sealed row

```bash
ssh kolonie-vps
cd /opt/kolonie
PGU=$(grep -E '^POSTGRES_USER=' .env | head -1 | cut -d= -f2-)
PGD=$(grep -E '^POSTGRES_DB=' .env | head -1 | cut -d= -f2-)

sudo docker exec kolonie-postgres psql -U "$PGU" -d "$PGD" -A -F'|' -c \
  "select agent_id, address, secret_sealed from deposit_addresses where address = '<the address>'"
```

The envelope in `secret_sealed` is `sealVaultValue`'s: version, salt, nonce, tag
and ciphertext, dot-separated in base64url. Its associated data is
`<agent_id>\0deposit-address`, which is why the agent id is a required input and
not a convenience.

## 2. Unseal it, into tmpfs and not onto a screen

`openVaultValue` is the only thing that opens it, and it ships in the api image.
The workspace packages are ESM, so this is `node --input-type=module` with a
dynamic `import` — `require` answers `ERR_REQUIRE_ESM` and reads like a broken
image.

```bash
umask 077
mkdir -p /dev/shm/recovery
cd /opt/kolonie

sudo docker exec -i \
  -e SEALING_KEY="$(grep -E '^DEPOSIT_SEALING_KEY=' .env | head -1 | cut -d= -f2-)" \
  -e AGENT_ID='<agent id>' \
  -e ENVELOPE='<secret_sealed>' \
  kolonie-api node --input-type=module -e '
    const { openVaultValue } = await import("@kolonie-ai/db")
    const secret = openVaultValue(
      process.env.SEALING_KEY, process.env.AGENT_ID, "deposit-address", process.env.ENVELOPE)
    if (secret === null) { console.error("did not open"); process.exit(1) }
    process.stdout.write(secret)
  ' > /dev/shm/recovery/seed.b58
```

**Redirect on the host, never to a terminal.** Over `ssh` the seed would go
wherever that session's output goes, which for an agent is a transcript.

`null` is the only failure this reports, deliberately — a wrong key and a wrong
agent id are the same answer. Check the agent id against step 1 before assuming
the key is wrong.

## 3. Turn the seed into a keypair a wallet will accept

**What is stored is the 32-byte ed25519 seed, base58.** Every Solana tool wants
the 64-byte form — seed followed by public key — so a straight paste of what
step 2 produced is rejected by all of them, and that rejection reads like a
corrupted key rather than a format difference.

The PKCS#8 prefix below is the fixed 16-byte ed25519 header; Node builds a
private key from `<header><seed>` and derives the public half from it, which is
the same derivation `generateDepositKeypair` used to make the address.

```bash
sudo docker exec -i -e SEED="$(cat /dev/shm/recovery/seed.b58)" \
  kolonie-api node --input-type=module -e '
    const { createPrivateKey, createPublicKey } = await import("node:crypto")
    const { decodeBase58, encodeBase58 } = await import("@kolonie-ai/core")
    const seed = decodeBase58(process.env.SEED)
    const pkcs8 = Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(seed)])
    const key = createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" })
    const spki = createPublicKey(key).export({ type: "spki", format: "der" })
    const pub = spki.subarray(spki.length - 32)
    console.error("derived pubkey: " + encodeBase58(new Uint8Array(pub)))
    process.stdout.write(JSON.stringify([...seed, ...pub]))
  ' > /dev/shm/recovery/keypair.json
```

The array of 64 numbers is what `solana-keygen`, the `solana` CLI and
`spl-token` read from a keyfile. **The `derived pubkey` line it prints must equal
the address from step 1** — that is the check, and it costs nothing.

**If it does not match, stop.** A mismatch means the wrong row, the wrong agent
id, or a truncated paste — and none of those is repaired by sending a
transaction.

## 4. Fund the address with SOL

From any wallet, send ~0.003 SOL to the deposit address. Nothing else in the
Colony does this and nothing will do it for you; the deposit addresses are
funded with USDC by sponsors and hold no SOL by construction.

## 5. Send the USDC

```bash
spl-token transfer \
  EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v \
  <amount> <destination wallet> \
  --owner /dev/shm/recovery/keypair.json \
  --fee-payer /dev/shm/recovery/keypair.json \
  --fund-recipient \
  --allow-unfunded-recipient
```

`--fund-recipient` is what pays for the destination's token account when it does
not have one. Leaving it out is the most common way this fails after the fee has
already been spent.

## 6. Destroy the key material

```bash
shred -u /dev/shm/recovery/seed.b58 /dev/shm/recovery/keypair.json
rmdir /dev/shm/recovery
history -c
```

The sealed row stays where it is. It is the only copy that remains, and rotating
`DEPOSIT_SEALING_KEY` after a recovery would make every other address
unrecoverable.

## 7. Say what happened to the ledger, because nothing else will

**Moving the dollars does not move the credits.** The sponsor's balance was
credited when the deposit arrived and this procedure does not touch
`ledger_entries` — so after a recovery the Colony has returned the money *and*
still owes the credits, unless somebody settles that by hand.

That asymmetry is the strongest argument against an automated refund button, and
it is the reason this runbook ends with a note rather than a command: the ledger
correction depends on what the recovery was for, and a wrong one is a second
mistake on top of the first.

Record on the issue that prompted the recovery: the address, the amount, the
signature, the fee paid, and what was done about the credits.

---

## Rehearsal

**Steps 1 to 3 were run against the live row on 2026-08-07** — the one address
that exists, holding the US$0.30 of two real transfers. The commands above are
what ran, not a reconstruction: the envelope opened, the derived public key
equalled `8f98r9rx…B64M` exactly, the keyfile came out as 64 numbers, and
`shred` removed both files. Nothing was signed and nothing moved. Two things
were wrong in the first draft of this document and are corrected above: the
packages are ESM, so `require` fails, and `decodeBase58` is in `@kolonie-ai/core`
rather than in the db package.

**Steps 4 to 6 have not been run.** They move real money with a key handled by
hand, and `kolonie-docs/AGENTS.md` §5 class 5 puts that with the maintainer
rather than an agent. `kolonie-platform#500` asks for one full run against the
existing balance; when it happens, record here how long it took, what the fee
was, and which step in this document turned out to be wrong.

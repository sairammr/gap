# src-aqua — codehash-exact Aqua mirror (placeholder)

`[profile.aqua]` in `foundry.toml` points `src = "src-aqua"` and is configured to
mirror 1inch's hardhat build exactly (evm_version = prague, via_ir = true,
optimizer_runs = 10_000_000). Building `Aqua` under that profile is what reproduces
the official mainnet runtime codehash
`0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8`.

## Status: NOTE PLACEHOLDER (real mirror not vendored)

This directory does NOT yet contain a copy of the full `@1inch/aqua` source tree.
The live Base Sepolia demo uses the **default-profile** Aqua deployed by
`script/DeployAqua.s.sol` / `script/DeployGap.s.sol`. Under the default profile the
deployed Aqua's codehash will **MISMATCH** the mainnet codehash — the scripts log
this (match/mismatch) WITHOUT reverting, which is expected and acceptable for the demo.

## To make the codehash match (optional, for a byte-identical mainnet build)

Copy the Aqua Solidity sources and their transitive imports here so the tree resolves
under `src-aqua`, e.g.:

    cp -R node_modules/@1inch/aqua/contracts/* src-aqua/

and vendor the `@1inch/solidity-utils` and `@openzeppelin/contracts` imports Aqua
pulls in (or add remappings scoped to `[profile.aqua]`), then:

    ~/.foundry/bin/forge build --profile aqua

The resulting `out-aqua/Aqua.sol/Aqua.json` runtime codehash should then equal the
mainnet value above. This was deliberately left as a placeholder because a full,
correctly-remapped vendoring of the aqua dependency tree under a second profile is
non-trivial and is not required for the live demo.

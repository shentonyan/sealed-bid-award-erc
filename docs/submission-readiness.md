# ERC-8469 submission review

## Current status — 2026-10-27

Editor associate abcoathup assigned ERC-8469 in PR review comment 4384323800
and supplied the updated forum URL in comment 4384333447. Both suggestions are
applied: `eip: 8469`, `ERCS/erc-8469.md`, `assets/eip-8469/`, and the new
`discussions-to` URL. The `created` date is the number-assignment date, 2026-10-27.
The earlier notes below describe the pre-number submission history.

## Initial review — 2026-10-26

The ERC submission contains the specification, two interfaces, the tender, four
mechanisms and their base contract, and JSON award vectors. The adapters are
integration examples maintained here, outside the normative submission assets.

## Content binding

`AwardThenMint.open` takes a nonzero work-description hash. It constructs the full
descriptor using `contentHashFor`: ABI-encoded domain
`keccak256("sealed-bid.task.native.v1")`, work hash, chain id, native asset marker
`address(0)`, integer unit `1` (one native smallest unit), and inner verifier.
That descriptor hash is stored in the job and the tender's `contentHash`.

Settlement supplies the descriptor hash to the integration-specific mint function
and checks the resulting `taskHashOf` atomically. The adapter retains update
authority and has no update function. Fulfillment checks content equality again.
The verifier must be immutable with configuration fixed by its deployment; this
is an integration assumption, not something the companion can infer from an address.

Tests cover nonzero input, exact descriptor encoding, exact initial minted content,
unauthorised updates, a minter ignoring the hash (including rollback), and later
content corruption. A faulty or upgradeable target can still violate the declared
profile; passing an equality check is not proof of target correctness or liveness.

## Authority and economics

The award grants no authority. An adapter may act only as the target's authorised
client or under a pre-authorisation. Passive adapters only validate transitions.
The specification and README scope Vickrey dominance to private costs, quasi-linear
utilities and the stated integration commitments, without collusion or externalities.
Revenue equivalence is not asserted for arbitrary plugins.

## Links and dependencies

The upstream ERC corpus at submission preparation contains ERC-8183 but not the
forum working drafts numbered 8195 and 8414. The normative submission describes
those latter patterns generically, avoiding links to nonexistent proposal files.
Their original discussion links remain in this repository's README.

`requires: 20, 165` covers the bond-token and interface-detection requirements.
ERC-8183 is informative composition context, not required to implement the companion.
Source and submission assets are checked for equality, and every local Markdown
link in the submission is checked against a present file or the upstream Git tree.

## Validation boundary

JavaScript/EVM tests and both core-Lean proof files are run locally. Foundry fuzz
tests run in repository CI. Lean proves the mathematical models; correspondence
with Solidity is exercised on finite test grids, not proved for all executions.
The ERC repository's own review and CI may request further editorial changes.

## Submitted PR and upstream preflight

Submitted as https://github.com/ethereum/ERCs/pull/2114 with status `Draft`.
Development CI run 40210495199 passed: 1,046 JavaScript/EVM assertions, 30 Foundry
tests (including fuzzing), and both Lean files with the axiom checks.

Upstream spelling, Markdown, link and security checks passed. The upstream
`eipw-action` rejects the `erc-draft_...` filename before inspecting its contents
because its filename parser accepts a numeric suffix only. The submission keeps
the official pre-number draft convention rather than claiming a number.

The same document was also checked locally with `eipw-lint-js`, upstream
`config/eipw.toml`, and dependency files from the upstream corpus. Adding a
temporary local-only number and filename yielded zero diagnostics. That number
was never committed or submitted. Editor number assignment is still pending.

## HTML build correction

The initial full-site HTMLProofer run reported six broken attachment links. The
ERC website merge step renames `assets/erc-*` directories to `assets/eip-*`, but
does not rewrite links in the proposal. The submitted assets and their links now
use `assets/eip-draft_sealed_bid_award/` directly, so the same paths resolve in
the repository and in the built website. No CI checks or workflow files changed.

Upstream run 40212331301 confirmed that HTMLProofer and DNS Validator pass for
the attachment-path fix. The numeric-filename validator still requires editor
action, requested in PR comment 6400244707. A separate local run of
`markdownlint-cli2` with the upstream configuration found two missing blank lines
before citation fences; those are corrected and the local Markdown run is clean.

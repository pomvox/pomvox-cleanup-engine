# Security and trust boundaries

Pomvox Cleanup Engine handles transcripts supplied by its caller. The local implementation contains no upload, telemetry or model-download path. Selecting `CloudCleaner` explicitly authorizes a remote request; the client never changes routes, follows redirects or retries automatically.

## Supported use

This is an unreleased developer preview. No security audit or stable support window is claimed. Use a caller-trusted, immutable pack directory. Pack hashes detect mismatched bytes; they do not authenticate a publisher. The MLX runtime admits only the pinned artifact set tested by this repository. Executable pack plugins and custom tokenizer code are unsupported.

Validation opens regular files without following final-component symlinks, bounds reads, checks file metadata and hashes, and parses the verified metadata bytes. Cancellation is checked between chunks. Keep the directory and its parent directories under the caller's control and immutable through loading and inference. Validation does not defend against a hostile process that can replace those files afterward. The installer may follow symlinks in an already trusted source cache and creates regular destination files.

Local inference has a bounded queue and one resident model per process. Deadline and cancellation resolve callers while unresponsive computation retains its resources; they cannot interrupt a GPU kernel. A permanently hung worker can require process restart. This SDK is not a process-isolated sandbox for hostile models.

## Cloud client

Production endpoints require HTTPS. HTTP is allowed only for explicit loopback development. Endpoint credentials, queries and fragments are rejected. Credentials come from the host's `CredentialProvider`; do not embed them in source or manifests. Response bodies and edits are bounded and validated before delivery. The host remains responsible for obtaining consent, choosing a trustworthy endpoint, securing its credential provider and enforcing retention policy.

An arbitrary HTTPS URL is not an endorsed service. The client does not implement server authentication policy, billing, tenant isolation or premium model hosting. Do not ship the loopback test server.

## Reporting a vulnerability

Until a hosted repository and private security-advisory channel are established, contact the maintainer privately at **abhiram.304@gmail.com**. Do not post credentials, private transcripts or exploit details in public issues. Include the affected source revision, platform, a minimal synthetic reproduction and the boundary crossed. Do not run security probes against third-party services without authorization.

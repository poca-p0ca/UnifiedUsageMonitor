# Security

## What this app has access to

It reads OAuth credentials that the Claude Code, Codex and Antigravity CLIs
have already stored on your Mac, and uses them to call each service's usage
endpoint. It never asks you for a password or an API key, and never sends
anything anywhere except to those three vendors' own endpoints.

It does refresh those credentials. An access token lasts hours, so keeping a
gauge alive means exchanging the refresh token for a new one and storing the
result where the tool keeps it — the same thing the tool's own CLI does when it
runs.

There is no telemetry, no analytics and no network destination other than
`api.anthropic.com`, `chatgpt.com`, `auth.openai.com`,
`cloudcode-pa.googleapis.com` and `oauth2.googleapis.com`.

## What it writes

| Path | Contents |
|---|---|
| `~/Library/Logs/UnifiedUsageMonitor/*.json` | the last raw response from each provider |
| `~/Library/Logs/UnifiedUsageMonitor/monitor.log` | timestamps, provider IDs, HTTP statuses, error text |
| `~/.codex/auth.json` | rewritten in place, mode 0600, when a Codex token is refreshed |
| keychain `Claude Code-credentials` | rewritten when a Claude token is refreshed, with only the OAuth fields replaced |
| keychain `poca.p0ca.UnifiedUsageMonitor` | the app's own copy of the Antigravity refresh token and the OAuth client that works for it |

Tokens are never written to the log. Usage JSON can contain account
identifiers, so read those files before attaching them to an issue.

Writing to Claude Code's own keychain item is not incidental, so it is worth
being explicit: Anthropic rotates the refresh token, so a refresh this app
performed and failed to store would break the CLI's login. It re-reads the
credential immediately before the exchange and writes the original blob back
with only the OAuth fields replaced. Antigravity needs none of this — Google
does not rotate that refresh token, so the app keeps its own copy and never
writes to the CLI's item.

## Vendor credentials

The Antigravity OAuth `client_id` / `client_secret` pairs belong to Google and
are **not** stored in this repository. `AntigravityClients.swift` reads them
from the Antigravity CLI binary already installed on the machine and caches the
working pair in a keychain item this app owns. The Claude and Codex client IDs
are constants, because those are public identifiers with no accompanying
secret.

## Reporting a vulnerability

Open a [security advisory](https://github.com/poca-p0ca/UnifiedUsageMonitor/security/advisories/new)
rather than a public issue, and give it a few days.

If the issue is with one of the vendors' endpoints rather than with this app,
please report it to that vendor.

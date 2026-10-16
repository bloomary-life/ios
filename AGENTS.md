# AGENTS.md — Bloomary ios

Instructions for AI agents. Humans: [CONTRIBUTING.md](CONTRIBUTING.md); same rules.

## Repository

| # | Item | Value |
|---|---|---|
| 1 | What | Bloomary iOS app (Swift) |
| 2 | Stack | Swift, SwiftUI, StoreKit, iOS 17+ |
| 3 | Test | `xcodebuild test -project Bloomary.xcodeproj -scheme Bloomary -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| 4 | Trace check | `scripts/trace-check.sh REQUIREMENTS.md BloomaryTests` |
| 5 | Requirements | [REQUIREMENTS.md](REQUIREMENTS.md), IDs `IOS-NNN` |
| 6 | Related repos | backend, ios, desktop, android, platform, landing in github.com/bloomary-life |

## Hard rules

| # | Rule |
|---|---|
| 1 | Never invent facts, APIs, file paths or test results. Unknown → say so in the PR. |
| 2 | Before coding: restate the requirement as `When X, Y.` with its ID. |
| 3 | Smallest diff that satisfies the requirement. No drive-by refactors or reformatting. |
| 4 | Every behaviour change gets a test tagged `Verifies: <ID>` that fails if the requirement is false. |
| 5 | Never delete, skip or weaken a failing test to pass CI. |
| 6 | Run tests yourself; paste real output. Never claim a run you did not do. |
| 7 | No secrets, tokens, `.env`, server IPs or hostnames in code, docs or tests. |
| 8 | Do not edit `LICENSE`, `CONTRIBUTING.md`, `AGENTS.md`, `.github/` unless that is the task. |

## Done = PR contains

| # | Field | Content |
|---|---|---|
| 1 | Requirement | ID + sentence |
| 2 | Code | Files / functions |
| 3 | Evidence | Test names + output (bug fix: fail before, pass after) |
| 4 | Not verified | What and why |
| 5 | AI use | Tool + model |

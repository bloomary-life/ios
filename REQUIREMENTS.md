# Requirements — Bloomary ios

Format and evidence rules: [CONTRIBUTING.md](CONTRIBUTING.md). Check: `scripts/trace-check.sh REQUIREMENTS.md BloomaryTests`.

| ID | Requirement (When X, Y.) | Source | Status |
|---|---|---|---|
| IOS-001 | When the app is launched by the test runner, Sentry and TelemetryDeck are not started, so test runs never reach production dashboards. | Sentry "App Hanging" reports from CI runs, 2026-10-16 | active |
| IOS-002 | When a member publishes a saved draft, the post request carries its `draftId`, so the backend drops that draft's schedule. | Kat, 2026-10-22 | active |
| IOS-003 | When a member taps Unschedule on a scheduled draft, the app sends `DELETE /api/linkedin/schedule` with that draft's ID. | Kat, 2026-10-22 | active |
<!-- Add rows like:
| IOS-001 | When <condition>, <system> <observable result>. | <issue / spec link> | active |
-->

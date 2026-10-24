# Tidemark

Tidemark keeps every request [Surge](https://nssurge.com) handles in PostgreSQL, rolls each request up to
the app that caused it (through the process tree), and alerts you the first time a monitored app reaches a
new domain or IP.

* Live request log with process chain, policy, rule, remote IP and timing for every connection
* Per-app inventories of domains and IPs, with NEW markers and macOS notifications on first contact
* Site Probe: open a URL in an isolated browser and record every host it touches
* Egress IP per Surge policy, with a change log
* Several Macs can share one database

Requires macOS 27, Surge Mac 6.10+ (`surge-cli`), and PostgreSQL 14+.

## Build

Open `Tidemark.xcodeproj` in Xcode 27 and run the Tidemark scheme. From the command line:

```bash
xcodebuild -project Tidemark.xcodeproj -scheme Tidemark -destination 'platform=macOS' build
```

The project uses synchronized folders: every file under `Tidemark/` and `TidemarkTests/` belongs to its
target automatically, so adding a file never requires editing the project.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works.

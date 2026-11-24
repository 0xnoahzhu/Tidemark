# Releasing

A release is published by pushing a version tag. `.github/workflows/release.yml` runs on a self-hosted Mac runner and
publishes two files to the GitHub release, nothing else:

* `Tidemark-<version>.dmg`: signed with Developer ID, notarized and stapled. People install from it, and Sparkle
  downloads it to update the app.
* `appcast.xml`: Sparkle's feed, with one item for that DMG (its EdDSA signature, size and release notes).

The app reads `https://github.com/0xnoahzhu/Tidemark/releases/latest/download/appcast.xml` (`SPARKLE_FEED_URL`), which
GitHub serves from the newest published release. It checks once a day, and from Tidemark › Check for Updates…. Only
Release builds whose `SPARKLE_PUBLIC_ED_KEY` is set update themselves. The debug symbols stay on the runner, in
`~/TidemarkReleases/<version>/`.

## Making a release

1. Commit `chore(release): X.Y.Z`, which bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares
   the build number, which must always grow) in `Tidemark.xcodeproj/project.pbxproj`.
2. Tag it and push both:

   ```bash
   git tag vX.Y.Z && git push origin main vX.Y.Z
   ```

The workflow checks that the tag matches `MARKETING_VERSION`, that it is on `main` and that the Sparkle key is set.
The release notes list the `feat` and `fix` commits since the previous `chore(release)` commit
(`scripts/release-notes.sh`), unless `docs/releases/<version>.md` is written by hand. Its `# ` line is the
release's title.

## One-time setup of the runner Mac

Everything secret stays in the runner's login keychain; the repository holds no secrets.

1. **Xcode 27** at `/Applications/Xcode.app`, then `xcodebuild -runFirstLaunch`. Install
   [uv](https://docs.astral.sh/uv/) and [gh](https://cli.github.com).
2. **Developer ID certificate.** On the Mac that has it, export "Developer ID Application: … (7939U549K7)" with its
   private key from Keychain Access as a `.p12`, and import it into the runner's login keychain. Check with
   `security find-identity -v -p codesigning`.
3. **Notarization.** Create an App Store Connect API key (Users and Access › Integrations, role Developer) or use an
   app-specific password, and store it as a keychain profile:

   ```bash
   xcrun notarytool store-credentials tidemark-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
   ```

   Another name works too: set it as the repository variable `NOTARY_PROFILE`.
4. **Sparkle key.** Build once so SwiftPM fetches Sparkle, then generate the EdDSA key pair into the login keychain:

   ```bash
   xcodebuild -resolvePackageDependencies -project Tidemark.xcodeproj -scheme Tidemark -derivedDataPath build/DerivedData
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Put the printed public key in `SPARKLE_PUBLIC_ED_KEY` (Debug and Release) and commit it. Back up the private key
   (`generate_keys -x sparkle-private.key`) somewhere safe: without it no installed copy can be updated again.
5. **Runner.** In the repository's Settings › Actions › Runners, add a new self-hosted macOS runner and follow its
   steps; it gets the labels `self-hosted`, `macOS` and `ARM64`. Install it as a service (`./svc.sh install` and
   `./svc.sh start`) so it runs as a LaunchAgent in the logged-in user's session, where the keychain is unlocked. Turn
   on automatic login for that user, or the keychain stays locked after a restart.
6. **Fork safety.** The repository is public: under Settings › Actions › General, require approval for workflows from
   all outside collaborators. The release workflow runs only on tag pushes, which forks cannot make.

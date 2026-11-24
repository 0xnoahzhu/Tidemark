# Releasing

A release is published by pushing a version tag. `.github/workflows/release.yml` runs on GitHub's hosted `xcode-27`
image (macOS 27, Xcode 27; a fresh virtual machine every run, free for a public repository) and publishes two files
to the GitHub release, nothing else:

* `Tidemark-<version>.dmg`: signed with Developer ID, notarized and stapled. People install from it, and Sparkle
  downloads it to update the app.
* `appcast.xml`: Sparkle's feed, with one item for that DMG (its EdDSA signature, size and release notes).

The app reads `https://github.com/0xnoahzhu/Tidemark/releases/latest/download/appcast.xml` (`SPARKLE_FEED_URL`), which
GitHub serves from the newest published release. It checks once a day, and from Tidemark › Check for Updates…. Only
Release builds whose `SPARKLE_PUBLIC_ED_KEY` is set update themselves. The debug symbols are kept as the run's
`Tidemark-v<version>-dSYM` artifact for 90 days.

No self-hosted runner: the repository is public, and a pull request can bring its own workflow, which would run on
that machine.

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

`scripts/release.sh` also runs locally with the Developer ID certificate in the login keychain; it notarizes when
`TIDEMARK_NOTARY_PROFILE` names a `notarytool store-credentials` profile, and otherwise leaves the DMG unnotarized.

## One-time setup

The secrets live in the repository's `release` environment, which only the release workflow uses and only a `v*` tag
may deploy to. The certificate and the App Store Connect API key are the same ones Folio uses.

1. **The environment**, limited to `v*` tags:

   ```bash
   gh api -X PUT repos/0xnoahzhu/Tidemark/environments/release \
     -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/0xnoahzhu/Tidemark/environments/release/deployment-branch-policies -f name='v*' -f type=tag
   ```

2. **Signing and notarization secrets.** `CSC_LINK` is the Developer ID Application certificate with its private key
   (a `.p12` exported from Keychain Access), base64-encoded:

   ```bash
   base64 -i DeveloperID.p12 | gh secret set CSC_LINK --env release --repo 0xnoahzhu/Tidemark
   gh secret set CSC_KEY_PASSWORD --env release --repo 0xnoahzhu/Tidemark
   gh secret set APPLE_API_KEY --env release --repo 0xnoahzhu/Tidemark < AuthKey_XXXXXXXXXX.p8
   gh secret set APPLE_API_KEY_ID --env release --repo 0xnoahzhu/Tidemark --body XXXXXXXXXX
   gh secret set APPLE_API_ISSUER --env release --repo 0xnoahzhu/Tidemark --body <issuer-id>
   ```

3. **The Sparkle key.** Generate the EdDSA key pair into your login keychain (which keeps the private key; without
   it no installed copy can be updated again), store the private key as a secret, and put the public key in
   `SPARKLE_PUBLIC_ED_KEY` (Debug and Release):

   ```bash
   xcodebuild -resolvePackageDependencies -project Tidemark.xcodeproj -scheme Tidemark -derivedDataPath build/DerivedData
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account tidemark
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account tidemark -x sparkle.key
   gh secret set SPARKLE_PRIVATE_KEY --env release --repo 0xnoahzhu/Tidemark < sparkle.key && rm sparkle.key
   ```

4. **Pull requests from forks.** Under Settings › Actions › General, require approval for workflows from all outside
   collaborators.

# Publishing to Maven Central

Publishing is gated by a non-prerelease GitHub Release. Pushes and pull
requests only build and test; they never publish.

## Release procedure

1. Set the same non-SNAPSHOT release version in the parent and module poms,
   including the SCM tag, and update versioned documentation.
2. Merge the release commit to `main` and wait for CI to pass.
3. Publish a GitHub Release tagged `v<version>` and target it at that exact
   commit.
4. The release workflow validates that the tag matches `project.version`,
   rebuilds and tests the macOS ARM64, Windows x64, and Linux x64 natives from
   the tag, and deploys those exact artifacts to Maven Central.

The Central plugin uses `autoPublish=true` and waits until the deployment is
published. No separate portal approval is required.

Builds use the Maven Wrapper (`./mvnw`), which pins Maven 3.9.16. Do not
switch the release to the runner's `mvn`: under Maven 3.10 the
central-publishing plugin (0.11.0) stages resolver files such as
`_remote.repositories` and `maven-metadata-local.xml` into the bundle, and
Central rejects it with "Bundle has content that does NOT have a .pom file".

## Repo secrets

Configure these under Settings → Secrets and variables → Actions:

| Secret | Source |
|---|---|
| `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD` | A Central Portal user token, split into its username and password |
| `GPG_PRIVATE_KEY` | ASCII-armored private key from `gpg --armor --export-secret-keys <KEYID>` |
| `GPG_PASSPHRASE` | Passphrase for that key |

The `io.github.ghosthack` namespace is already verified on Central.

## Recovery and local checks

If a release run fails, fix the underlying issue and rerun the entire workflow
with `gh run rerun <run-id> -R ghosthack/ffmpeg-ffm`. Rerunning only failed
jobs can lose access to native artifacts from the previous attempt.

`./mvnw -Prelease -Dgpg.skip=true clean verify` checks sources, javadocs, and
packaging locally without publishing. Releases are immutable: publish changed
content under a new version rather than rebuilding an existing version.

To inspect the signed bundle CI would upload, run the Release workflow
manually (`gh workflow run release.yml`, optionally with a throwaway
`version`). It rebuilds the natives, builds the bundle against an unreachable
Central URL with placeholder credentials, fails if it contains local resolver
files, and attaches `central-bundle.zip` as a workflow artifact; nothing is
published.

After a successful release, Maven Central mirrors can take several minutes to
serve the new artifacts.

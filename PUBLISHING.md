# Publishing to Maven Central

Releases publish **from GitHub Actions**, reusing the pipeline proven by
`imageio-native` (same portal account, same secret names, same
push-to-publish flow). `.github/workflows/ci.yml`:

1. `natives-macos` / `natives-windows` — build FFmpeg + dav1d **from source**
   on real runners via `build-natives/*.sh`, run the smoke tests against the
   result, upload the staged sets as artifacts. Runs on every push/PR.
2. `release` — on push to `main`: if the parent pom `<version>` changed and is
   not a SNAPSHOT, create GitHub release `v<version>`. (`workflow_dispatch`
   forces a deploy of the current version.)
3. `deploy` — downloads both native sets and runs
   `mvn clean deploy -P release,all-natives`: one deployment bundle containing
   parent + core (+sources/javadoc) + both natives classifier jars, signed,
   auto-published (`autoPublish=true`).

So the release procedure is: **stage natives nowhere, just bump the version in
the poms, commit, push to main.** CI does the rest.

## Repo secrets (Settings → Secrets → Actions)

Same four names as imageio-native — copy the values from wherever they are
kept (GitHub cannot display existing secrets; regenerate if lost):

| Secret | Source |
|---|---|
| `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD` | central.sonatype.com → Account → user token (regenerating invalidates the old one — update imageio-native's secrets too if you regenerate) |
| `GPG_PRIVATE_KEY` | `gpg --armor --export-secret-keys <KEYID>`; if the key exists only as imageio-native's secret, generate a fresh key, `gpg --keyserver keyserver.ubuntu.com --send-keys <KEYID>`, and use that |
| `GPG_PASSPHRASE` | passphrase of that key |

The `io.github.ghosthack` namespace is already verified on the portal (it
published imageio-native), so no namespace setup is needed.

## Local fallback

`mvn -Prelease -Dgpg.skip=true clean verify` dry-runs the build side (sources,
javadoc, packaging) with no keys. A full local deploy additionally needs the
portal token in `~/.m2/settings.xml` (server id `central`) and a local gpg key
— neither is normally present; prefer the CI path.

## Notes

- Version discipline: releases are immutable — any change is a version bump
  (`<ffmpeg>-<binding-train>` scheme, see README), never a rebuild-in-place.
- The natives module is `pom`-packaging with attached classifier jars, so
  Central's sources/javadoc rule does not apply to it; if portal validation
  ever objects, attach empty `-sources`/`-javadoc` jars via extra
  `maven-jar-plugin` executions.
- First CI run on a new runner image is the risky one (brew/msys2 package
  drift); the natives jobs run on every push, so breakage surfaces before a
  release, not during one.

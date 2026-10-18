# Release signing (Developer ID + notarization)

Signed/notarized builds are produced automatically by GitHub Actions when a
`v*` tag is pushed (or via manual dispatch). Nothing secret is stored in the
repo; all credentials are encrypted GitHub Actions secrets.

## How a release is made

```bash
git tag v1.0.0
git push origin v1.0.0
```

## How a release is made

```bash
git tag v1.0.0          # or v1.0.0-canary.1 for a canary
git push origin v1.0.0
```

Only the repository owner can push tags, so only the owner can trigger a
signed release.

### Why pull requests / forks cannot steal the certificate

- The signing job references every secret (`ASC_*`, the `.p12`). GitHub does
  not expose repository secrets to workflows running in a `pull_request`
  context from a fork or an outside collaborator — those runs get no secrets.
- The workflow only runs signing on a `v*` / `v*-canary` **tag** (or a manual
  `workflow_dispatch`). There is no `pull_request` trigger at all.
- A first `gate` job independently checks that the repository owner is
  `deepcoldy` and the ref is a release tag; the signing job is skipped
  (`if: needs.gate.outputs.allowed`) otherwise.
- Secret values are auto-masked as `***` in logs, and the step that writes
  them to disk runs with `umask 077` into a runner-only `.asc-work/` folder
  that is deleted in a final `always()` cleanup. The `.p12` is never a
  workflow artifact and is never printed.
- For an additional human checkpoint you can enable **deployment protection /
  required reviewers** on the `release` environment in
  Settings → Environments; every signed run would then wait for your approval.

The workflow (`.github/workflows/build.yml`) then, on a macOS runner:

1. Installs `asc` and authenticates with the App Store Connect API key.
2. Builds the universal `SwitchMux` binary and the capture helper.
3. Assembles the `.app` and icon.
4. Imports the Developer ID `.p12` into a throwaway keychain (the runner's
   keychain is left untouched) and signs the helper then the app with
   `--options runtime --timestamp`.
5. Builds and signs a DMG.
6. `asc notarization submit --wait` → `staple` → `validate`.
7. Publishes the DMG to the GitHub Release.

The downloaded DMG passes Gatekeeper: the app reports
`source=Notarized Developer ID`, so users open it with no security warning.

## One-time setup (already done)

A paid Apple Developer Program membership is required (free Apple IDs cannot
get Developer ID / notarization).

### Why the certificate was created manually

Apple allows the App Store Connect API to read/create most objects, but
creating a **Developer ID Application** certificate is forced through the
account holder's interactive browser session — even an Admin-role API key gets
`This operation can only be performed by the Account Holder`. `asc web` (the
authenticated Apple-ID session) does not implement certificate creation
either. So the certificate CSR must be uploaded once at:

<https://developer.apple.com/account/resources/certificates/add>

Pick **Developer ID Application (G2)** and upload a CSR generated locally.
An individual account holds up to 5 of these certificates; the existing ones
keep working and do not need to be deleted.

### Local key generation (if the certificate ever needs renewing)

```bash
mkdir -p signing && cd signing
# CSR with a normal subject (an "asc"-generated CN=asc CSR was rejected)
openssl req -new -newkey rsa:2048 -nodes \
  -keyout devid.key -out devid.csr \
  -subj "/emailAddress=APPLE_ID/CN=YOUR NAME/C=CN"
# -> upload devid.csr in the portal, download developerID_application.cer
openssl x509 -in developerID_application.cer -inform DER -out DeveloperID.pem -outform PEM
openssl pkcs12 -export -inkey devid.key -in DeveloperID.pem \
  -out DeveloperID.p12 -passout pass:"$P12_PASSWORD"
```

Verify the cert and key match before packaging:

```bash
[ "$(openssl x509 -in DeveloperID.pem -noout -modulus | openssl md5)" \
  = "$(openssl rsa -in devid.key -noout -modulus | openssl md5)" ] && echo match
```

### GitHub secrets

| Secret | Contents |
|---|---|
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_PRIVATE_KEY` | Contents of the `AuthKey_*.p8` API key |
| `ASC_DEVELOPER_ID_CERT_P12` | `base64 DeveloperID.p12` |
| `ASC_DEVELOPER_ID_CERT_PASSWORD` | The `.p12` export password |

Set file-valued secrets by piping, never pasting into logs:

```bash
gh secret set ASC_PRIVATE_KEY             < AuthKey_XXXX.p8
gh secret set ASC_DEVELOPER_ID_CERT_P12   < <(base64 -i signing/DeveloperID.p12)
```

## Important detail: the G2 intermediate certificate

The `.p12` alone imports into a fresh keychain as a certificate **without a
valid identity**, because the leaf needs Apple's `Developer ID Certification
Authority (G2)` intermediate in the same keychain. The workflow downloads
<https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer> and imports
it **before** the `.p12`. Without this step `find-identity` reports 0 valid
identities and codesigning silently falls back to ad-hoc.

## Local development

`./build.sh` produces an ad-hoc signed `build/SwitchMux.app` — fine for local
use, no Apple credentials needed.

## Backing up the private key

`signing/` is git-ignored and contains the only copy of the Developer ID
private key (`devid.key` / `DeveloperID.p12`). Back this folder up securely
(password manager / encrypted volume). The Apple portal can re-download the
public certificate but never the private key; losing it means creating a new
certificate against the quota.

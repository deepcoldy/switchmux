# Release signing (Developer ID + notarization)

Signed/notarized builds are produced automatically by GitHub Actions when a
`v*` tag is pushed (or via manual dispatch). This document covers the one-time
credential setup. Nothing secret is stored in the repository.

## Prerequisite

A paid **Apple Developer Program** membership. Signing/notarization cannot be
done with a free Apple ID.

## 1. App Store Connect API key (Admin / Account Holder)

The API key used for certificate creation must have the **Admin** role (or be
created by the Account Holder). A Developer-role key can read data but gets
`This operation can only be performed by the Account Holder` when creating
Developer ID certificates.

Create or re-create the key at:
<https://appstoreconnect.apple.com/access/integrations/api>

You get an Issuer ID, a Key ID, and a one-time-download `AuthKey_XXXX.p8`.

## 2. Register the bundle ID

```bash
asc auth login --name ci \
  --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID" \
  --private-key ./AuthKey_XXXX.p8 --network
asc bundle-ids create --identifier dev.shenhan.switchmux \
  --name "SwitchMux" --platform MAC_OS
```

## 3. Create the Developer ID certificate and export .p12

```bash
mkdir -p signing && cd signing
asc certificates create --certificate-type DEVELOPER_ID_APPLICATION \
  --generate-csr --key-out ./devid.key --csr-out ./devid.csr
# Download the issued .cer from App Store Connect (or use asc if supported):
asc certificates list --certificate-type DEVELOPER_ID_APPLICATION
# Once DeveloperID.cer is in this folder:
openssl x509 -in DeveloperID.cer -inform DER -out DeveloperID.pem -outform PEM
openssl pkcs12 -export \
  -inkey devid.key -in DeveloperID.pem \
  -out DeveloperID.p12 -passout pass:"$P12_PASSWORD"
```

## 4. Store secrets in GitHub

Everything below is stored as an **encrypted GitHub Actions secret** and never
appears in logs or the repo:

```bash
gh secret set ASC_KEY_ID                   --body 'XXXXXXXXXX'
gh secret set ASC_ISSUER_ID               --body '00000000-0000-0000-0000-000000000000'
gh secret set ASC_PRIVATE_KEY             < AuthKey_XXXXXXXXXX.p8
gh secret set ASC_DEVELOPER_ID_CERT_P12   < signing/DeveloperID.p12 | base64 |
gh secret set ASC_DEVELOPER_ID_CERT_PASSWORD --body "$P12_PASSWORD"
```

> `ASC_PRIVATE_KEY` / the `.p12` are file contents; pipe them in, don't paste.

## 5. Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow builds the universal binary (including the capture helper), signs
both with Developer ID, packages a signed DMG, notarizes with `asc
notarization submit --wait`, staples the ticket, and publishes the DMG to the
GitHub Release. Downloads open without Gatekeeper warnings.

## Local (unsigned) development builds

`./build.sh` keeps producing an ad-hoc signed `build/SwitchMux.app` — fine for
local use, no Apple credentials needed.

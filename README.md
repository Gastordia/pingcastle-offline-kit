# PingCastle offline bundle

Private transfer repository for the authorized AD configuration audit. The
archive is split because the original `PingCastle.exe` exceeds GitHub's normal
100 MB per-file limit.

## Reassemble and verify on Ubuntu

```bash
cat pingcastle-max.7z.part-* > pingcastle-max.7z
sha256sum pingcastle-max.7z
```

Expected SHA-256:

```text
c9d4fcd91075d9009833c579410491f0266a6c6421c181d67a8829c5d8812243
```

Extract:

```bash
sudo apt update
sudo apt install -y p7zip-full
7z x pingcastle-max.7z
```

Individual part hashes are stored in `SHA256SUMS`.

## Handling

Keep this repository private. The bundle and generated reports may contain
licensed configuration and sensitive Active Directory assessment data.


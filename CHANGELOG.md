# Changelog

## 0.1.0 - Unreleased

- Create a standalone `BlissMixerExt` plugin identity.
- Add the independent **Bliss (Ext)** Don't Stop the Music provider.
- Reuse upstream Bliss Mixer preferences and its read-only analysis database.
- Isolate experimental mixer and learner binaries under Ext-specific names.
- Move the similarity survey, triplets, backups, and learned matrix into the
  sidecar namespace.
- Add an automated, checksum-verified release workflow that publishes all three
  platform packages and updates the LMS plugin feed.

# Changelog

## 0.1.3 - 2026-09-03

- Match BlissMixer's persistent training-data backup folder control.
- Match BlissMixer's icon-only backup restore picker and automatic restore
  behavior after selecting a ZIP file.

## 0.1.2 - 2026-09-02

- Restore the LMS slider control for Learned matrix influence.
- Remove the mixer port from the user-facing settings and automatically select
  an available loopback port for the experimental mixer process.

## 0.1.1 - 2026-09-02

- Fix the LMS string catalog delimiters so the plugin name and settings labels
  are localized instead of appearing blank or as raw string IDs.
- Validate the string catalog format and every settings-page localization token
  in CI.

## 0.1.0 - 2026-09-02

- Create a standalone `BlissMixerExt` plugin identity.
- Add the independent **Bliss (Ext)** Don't Stop the Music provider.
- Reuse upstream Bliss Mixer preferences and its read-only analysis database.
- Isolate experimental mixer and learner binaries under Ext-specific names.
- Move the similarity survey, triplets, backups, and learned matrix into the
  sidecar namespace.
- Add an automated, checksum-verified release workflow that publishes all three
  platform packages and updates the LMS plugin feed.

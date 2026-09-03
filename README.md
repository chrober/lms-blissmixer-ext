# Bliss Mixer Extensions

BlissMixerExt is an independent extension plugin providing experimental and
early-access features for
[Lyrion Media Server](https://lyrion.org/). It requires the upstream
[Bliss Mixer](https://github.com/CDrummond/lms-blissmixer) plugin and adds a
separate **Bliss (Ext)** provider to Don't Stop the Music.

BlissMixerExt does not replace or modify the installed Bliss Mixer plugin. It
exists as a staging channel where early adopters can test features before they
are proposed for upstream Bliss Mixer.

## Responsibilities

- Upstream Bliss Mixer analyses the music library and owns `bliss.db`.
- BlissMixerExt reads that database and the upstream mix preferences.
- BlissMixerExt owns its mixer and learner processes, experimental preferences,
  survey data, and learned similarity matrix.
- The standard **Bliss** and experimental **Bliss (Ext)** DSTM providers can be
  installed and selected side by side.

BlissMixerExt currently requires Bliss Mixer 0.10.0 or newer and LMS 9.0 or
newer.

## Installation

Release packages include platform-specific `bliss-mixer-ext` and
`bliss-learner` executables. Install the appropriate release through the LMS
plugin manager or extract it into the LMS plugins directory, then restart LMS.

For development, place or symlink the `BlissMixerExt` directory in the LMS
plugins directory and run:

```text
python download-binaries.py
```

Enable both Bliss Mixer and Bliss Mixer Extensions. Run library analysis from
the upstream Bliss Mixer settings, configure experimental options on the
BlissMixerExt settings page, and select **Bliss (Ext)** under Don't Stop the
Music.

Metric learning reports its live start time, elapsed duration, and current
native training phase on the settings page. The installed upstream BlissMixer
version shown under Companion status is read from LMS's loaded plugin manifest.

The experimental play-count influence can favor either less-played or
frequently played tracks while preserving acoustic similarity as a ranking
signal. It uses LMS's built-in listening statistics, which are enabled by
default. If LMS was started with `--nostatistics`, remove that command-line
option and restart the server; there is no corresponding web setting.

When Adaptive weighting and Last.fm artist weighting are enabled in upstream
BlissMixer, the optional similar-track guidance asks LastMix for recordings
related to the current DSTM seeds. Recording MBIDs are preferred, with
normalized artist/title matching as a fallback. Only candidates already
returned by Bliss can be selected, and unavailable, partial, slow, or malformed
Last.fm responses degrade to the evidence available at the deadline or to
Bliss alone.

INFO-level selection logs label Last.fm evidence in the centered first column:
`(a)` means artist similarity, `(t)` means recording similarity, and `(a+t)`
means both. Numeric support scores and calculated weights are available only at
DEBUG level.

## Compatibility and isolation

The sidecar deliberately does not register an analyser, importer, Bliss Mixer
URL protocol, or replacement context-menu handlers. Its mixer listens only on a
separate automatically selected loopback port. It checks whether the
upstream analyser is active and reloads its mixer when `bliss.db` changes.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the staging and migration model.

## Testing

Every push and pull request runs repository validation, feed-update unit tests,
and the Perl plugin regression suite. The Perl tests exercise the sidecar's
upstream compatibility gate, DSTM identity and port isolation, inherited mixer
preferences, survey persistence and backup/restore, and learned-matrix
replacement behavior. It also covers Last.fm recording matching, partial
provider failures, and the combined selection signals. Release publication
runs the same test gate.

The separate `BlissMixer DSTM drift` workflow checks the current upstream
implementation every Monday and whenever the DSTM implementation or drift
configuration changes. Directly cloned routines must remain token-equivalent
after plugin-identity normalization. Intentionally adapted routines are compared
with the last reviewed upstream commit. Significant changes fail the workflow;
scheduled failures create or update a single review issue with per-routine
diffs.

After reviewing an upstream change, incorporate or intentionally reject each
relevant change and then advance `reviewed_upstream_commit` in
`compat/dstm-drift.json`. Do not advance the commit merely to silence the check.

On a Debian-based development system, run the complete plugin suite with
`prove -l tests` after installing the Perl dependencies listed in
`.github/workflows/validate.yml`.

## Release and publishing workflow

Pushing a semantic version tag runs `.github/workflows/release.yml`. It validates
the plugin, reads the pinned native releases from
`BlissMixerExt/Bin/SOURCE.md`, downloads and verifies every SHA-256 file, and
creates separate Linux, macOS, and Windows plugin packages. It publishes those
packages and their SHA-1/SHA-256 files as a GitHub Release, then updates the
three platform entries in `chrober/lms-plugins`.

Native release downloads and the feed update use the repository secret
`LMS_PLUGINS_TOKEN` (the legacy name `MS_PLUGINS_TOKEN` is also accepted) with
read access to the native repositories and contents-write access to
`chrober/lms-plugins`. A manual run with `dry_run=true` builds inspectable
workflow artifacts without publishing or changing the feed.

## Attribution and licence

This project contains code adapted from Craig Drummond's GPLv3-licensed
[lms-blissmixer](https://github.com/CDrummond/lms-blissmixer). The metric
learning work is based on `bliss-metric-learning` by Polochon-street.

BlissMixerExt is distributed under the GNU General Public License v3. See
[LICENSE](LICENSE).

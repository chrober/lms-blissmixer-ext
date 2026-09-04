# Binary provenance

Deployable executables are not committed to this repository. Release packages
consume checksum-verified assets from the native component repositories.

- Mixer release: `v0.10.0`
- Mixer commit: `67ee8b99822fca23cc3ffa8c410c949ca5ed973d`
- Learner release: `v0.1.1`
- Learner commit: `2b92fdfb96192e2d6cc690383894fcb255d5d1c0`

The plugin release workflow downloads the five platform assets and their
`.sha256` files from each release, verifies them, and installs them under these
the Ext-specific mixer name and the learner's canonical name:

- `x86_64-linux/bliss-mixer-ext` and `bliss-learner`
- `aarch64-linux/bliss-mixer-ext` and `bliss-learner`
- `armhf-linux/bliss-mixer-ext` and `bliss-learner`
- `mac/bliss-mixer-ext` and `bliss-learner`
- `windows/bliss-mixer-ext.exe` and `bliss-learner.exe`

Update and commit the release tags and source commits together before publishing
a plugin version with newer native components.

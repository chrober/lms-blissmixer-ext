# Binary provenance

Deployable executables are not committed to this repository. Release packages
consume checksum-verified assets from the native component repositories.

- Mixer release: `v0.9.0`
- Mixer commit: `7f4a72506e8e2db6a11e9f53b2bf1b43244c1184`
- Learner release: `v0.1.0`
- Learner commit: `063d165782fd6d9c1acb2378c8e5e2e2eb985c51`

The plugin release workflow downloads the five platform assets and their
`.sha256` files from each release, verifies them, and installs them under these
Ext-specific names:

- `x86_64-linux/bliss-mixer-ext` and `bliss-learner-ext`
- `aarch64-linux/bliss-mixer-ext` and `bliss-learner-ext`
- `armhf-linux/bliss-mixer-ext` and `bliss-learner-ext`
- `mac/bliss-mixer-ext` and `bliss-learner-ext`
- `windows/bliss-mixer-ext.exe` and `bliss-learner-ext.exe`

Update and commit the release tags and source commits together before publishing
a plugin version with newer native components.

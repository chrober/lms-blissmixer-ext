# Architecture

BlissMixerExt is a sidecar, not a runtime patch. It uses public LMS facilities
and shared on-disk analysis data but does not replace upstream Perl packages or
registrations.

## Ownership boundary

| Concern | Bliss Mixer | BlissMixerExt |
| --- | --- | --- |
| Library analysis and `bliss.db` writes | Owner | Read-only consumer |
| Stable mix preferences | Owner | Reads on every request |
| Experimental preferences | None | Owner |
| Mixer process | `bliss-mixer` | `bliss-mixer-ext` |
| Learning process | None | `bliss-learner-ext` |
| DSTM provider | `Bliss` | `Bliss (Ext)` |
| Survey, triplets, learned matrix | None | Owner |

The two preference namespaces are deliberately separate:

- `plugin.blissmixer` supplies filters, repeat limits, weights, seed strategy,
  genre groups, DSTM count, and Last.fm behavior.
- `plugin.blissmixerext` supplies only the sidecar port, learned blend, and
  training-data backup path.

## Database lifecycle

BlissMixerExt resolves `bliss.db` in the LMS preferences directory after plugin
initialization. Before each DSTM request it queries the existing upstream
`blissmixer analyser act:status` command. It stops its mixer while analysis is
active. It also records database size and modification time and restarts
`bliss-mixer-ext` after a database change.

No Ext code starts an analyser or opens the database for writes.

## Binary isolation

The experimental executables have unique installed filenames. The mixer binds
to `127.0.0.1` on a fixed Ext-owned port, avoiding the experimental binary's
upstream-specific dynamic-port callback. The learner is monitored as a local
child process and does not send notifications to the upstream CLI endpoint.

Learning writes to a temporary matrix. The active matrix is replaced only when
the learner produces a new result, preserving the previous model after a failed
experiment.

Native executables are released independently by `chrober/bliss-mixer` and
`chrober/bliss-learner`. BlissMixerExt pins both release tags and commits, checks
their published SHA-256 files, and renames the verified assets only while
assembling plugin packages. Workflow artifacts are never used as durable release
inputs.

## Feature graduation

When an experiment is accepted upstream:

1. Release an Ext version that recognizes the upstream version containing it.
2. Migrate any Ext preference or data that users should retain.
3. Remove the graduated setting and implementation from Ext.
4. Stop registering `Bliss (Ext)` when it no longer provides distinct behavior.

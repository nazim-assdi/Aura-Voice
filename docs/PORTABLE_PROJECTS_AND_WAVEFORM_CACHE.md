# Portable projects and waveform cache

## Portable project saves

The editor's Save action collects every referenced source WAV into a sibling
folder named `AuraProject_<project-id>.assets-<version>` and writes relative
asset paths into the existing `.aura.json` manifest. Repeated references to
the same canonical source file are copied once. Source recordings are never
modified.

To move a project to another computer, copy both:
- the `AuraProject_<project-id>.aura.json` manifest; and
- the matching `AuraProject_<project-id>.assets-<version>` folder.

On the target computer, copy both items directly into Aura Voice's
`Documents/Aura Voice Studio/Projects` folder, keeping the assets folder beside
the manifest. The saved-project browser lists manifests in that folder.
Opening the manifest resolves its relative media paths from the sibling assets
folder, so the original computer's absolute source paths are not required.
Older manifests with absolute paths remain supported. Saving again creates a
new asset folder, commits the updated manifest, and then removes superseded
asset folders for that project.

If an asset is unavailable, use the broken-link toolbar action to select the
missing source WAV. Relinking validates the WAV, project sample rate, channel
count, and every clip's source-frame range before changing clip references.

## Waveform cache

Waveform peak envelopes are cached as small JSON files under
`Documents/Aura Voice Studio/Cache/Waveforms`. The cache key distinguishes
source path and requested peak count. Each entry also records file size and
last-modified time; stale entries are recalculated. Corrupt or inaccessible
cache files are ignored and never prevent normal WAV analysis.

The cache is derived data and is safe to delete. The source WAV remains the
authoritative audio asset.

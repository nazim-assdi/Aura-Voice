# Aura Voice → Professional Video Studio: Architecture & Delivery Plan

## Product direction

Evolve the current Flutter/FastAPI voice-workspace scaffold into **Aura Studio**, a desktop-first, cross-platform non-linear video editor combining timeline editing, motion graphics, compositing, color, audio post-production and 3D/VFX workflows. All ongoing implementation is to be committed directly to the repository's existing `main` branch, as requested.

This is a staged engineering program, not a claim that the listed professional features already work. The current repository is an early voice-app scaffold: the README explicitly says speech inference is not implemented, and the current Flutter app has a dashboard plus placeholder Studio and Library pages. The video editor therefore needs a real media-engine foundation before advanced controls can be called complete.

## Product principles

1. Every visible control must change a real project property and be reflected in preview and export.
2. One project/timeline model is the source of truth for preview, background render and final export.
3. Preview may use proxies and reduced quality; final export must render full-resolution frames and audio.
4. Non-destructive editing: preserve source media and store edits as project data.
5. Desktop-first for the full editor (Windows, macOS, Linux); mobile is a review/rough-cut companion until hardware and OS APIs support equivalent workloads.
6. Be explicit about codec, GPU, platform and licensing limitations. Never label a placeholder as implemented.

## Proposed system architecture

### Client and editor shell
- Flutter desktop UI for workspace, panels, timeline, inspector, media bin, keyframe graph, scopes and render queue.
- Responsive Flutter mobile UI for capture, review, annotations and lightweight edits.
- Feature modules: project, media ingest, timeline, preview, effects, compositing, color, audio, tracking, 3D, export and preferences.
- A command/undo-redo layer and versioned project schema.

### Native media engine
- A Rust/C++ engine behind a stable FFI boundary; Flutter sends typed project commands and receives progress/events.
- FFmpeg libraries/CLI integration for probing, demux/decode, encode, mux, proxies and baseline filter/audio processing. Perform a per-build license audit and choose LGPL-compatible configurations where required; do not bundle GPL components without an explicit distribution decision.
- GPU effect graph using a cross-platform abstraction (evaluate wgpu/Vulkan/Metal/D3D12/OpenGL by target); CPU fallback for unsupported effects.
- Frame scheduler with source caching, proxy/original selection, parallel render tasks and deterministic frame timestamps.
- Separate preview and export render paths that share the same effect graph and project evaluation.

### Project and timeline model
- Versioned JSON project manifest with media references, sequence settings, tracks, clips, transforms, keyframes, effects, masks, transitions, audio routing, color settings and render settings.
- Rational frame rates and integer frame/timebase math; avoid floating-point drift.
- Track types: video, audio, title/graphics, adjustment and nested sequence.
- Clip operations: trim, slip, slide, ripple, roll, split, duplicate, speed change and nesting.
- Keyframe interpolation: hold, linear, Bezier/ease, spatial paths and per-property curves.
- Autosave journal, crash recovery, relinking and project migration.

## Feature implementation requirements

| Area | Required real behavior | Validation |
|---|---|---|
| Keyframes | Per-frame evaluation, Bezier graph, spatial paths, time remapping | Animated test sequence matches expected frames in preview and export |
| Audio layers | Multi-track routing, gain/pan automation, keyframes, sidechain ducking, meters and waveform cache | Rendered mix compared against reference levels and automation |
| Masks | Rectangle, ellipse, pen paths, feather, expansion, inversion, tracking attachment | Alpha/matte output tests and exported frame inspection |
| Blend modes | Implement and test standard compositing modes in linear-light/premultiplied-alpha pipeline | Golden-image tests for every supported mode |
| Transitions | Clip-to-clip transition nodes, handles, duration, easing and audio crossfades | Boundary-frame tests; no black flashes or dropped audio |
| Camera/light/3D | Real 3D scene graph, camera, lights, transforms, materials and render integration | Render known scene with deterministic camera/light output |
| Tracking | Point/planar tracking, track data, attach-to-transform/mask and lost-track recovery | Synthetic motion clips with known ground-truth paths |
| PSD | Layer import, visibility, hierarchy, supported blend modes and rasterized fallbacks | Compare imported composite against reference PSD renders |
| Glow/shadow/VFX | Multi-pass effect graph, blur kernels, glow threshold/radius, shadow maps where relevant | GPU/CPU parity tests and export-vs-preview frame comparison |

## Additional professional workflows

- Editing: multicam foundations, nested sequences, proxy relinking, markers, ripple editing, keyboard shortcuts and customizable workspaces.
- Color: scopes (waveform, vectorscope, histogram), lift/gamma/gain, curves, wheels, LUT management, shot matching and color-managed export.
- Audio: buses, meters, EQ, compressor, limiter, reverb, noise reduction integration, loudness measurement and stems.
- Titles/motion: vector/text layers, shape tools, path animation, templates, motion blur and reusable presets.
- VFX: chroma key, planar masks, stabilization, optical-flow evaluation, particles and node-based compositing.
- Delivery: render presets, codec/bitrate controls, alpha export where codec supports it, image sequences, audio stems and render queue recovery.
- Reliability: background rendering, cancellation, disk-space preflight, media relink, project backups and crash recovery.

## Delivery phases (acceptance gates)

### Phase 0 — Product and engine foundation
- Rename the product experience to Aura Studio while retaining repository identity.
- Add project schema, native-engine interface, capability reporting and feature flags.
- Add sample media/project fixtures and automated tests.
- Gate: a project opens, saves, reopens and evaluates a sequence at exact frame timestamps.

### Phase 1 — Editing core
- Media ingest/probe, thumbnails, waveform cache, proxy generation.
- Multi-track timeline, trim/split/ripple, transforms, titles, audio clips and undo/redo.
- Real-time preview with play/pause/scrub and audio sync.
- Gate: edit a sample sequence and export a playable video with synchronized audio.

### Phase 2 — Motion and compositing
- Keyframe graph, interpolation, masks, blend modes, transitions and adjustment layers.
- Gate: each feature has preview/export parity tests and golden-frame fixtures.

### Phase 3 — Audio post and color
- Audio buses, automation, ducking, effects and loudness tools.
- Color management, scopes, curves, wheels and LUT pipeline.
- Gate: mix and graded export match reference measurements within documented tolerances.

### Phase 4 — Tracking, PSD and 3D/VFX
- Tracking workflow, PSD import, 3D scene/camera/light integration and multi-pass effects.
- Gate: deterministic sample projects and platform-specific GPU test matrix.

### Phase 5 — Performance and release
- Proxy/adaptive playback, caching, render queue, crash recovery and packaging/signing.
- Gate: automated Windows/macOS/Linux builds, real hardware performance tests, codec/legal review and release checklist.

## Repository implementation rules

- Keep Flutter presentation separate from native media processing.
- Keep FastAPI optional for account/sync/AI services; local editing and export must not require a remote backend.
- Never upload user media without explicit opt-in.
- Do not download or bundle proprietary codecs, models, fonts or assets without license review.
- Every feature change committed to `main` must include a working sample project, tests, known limitations and preview/export parity evidence.

## Current status

This document is the architecture baseline only. The current app does not yet contain a functioning NLE, native render engine, full-resolution compositor, audio mixer, tracker or 3D renderer. These must be implemented and tested in the phases above.

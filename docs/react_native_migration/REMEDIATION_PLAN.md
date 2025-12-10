# React Native Migration Remediation Plan

## Purpose
Recent migrations in phases 7 and 8 introduced usability and reliability gaps that were caught during review. This plan enumerates the exact fixes required so the documentation and reference implementations stay trustworthy before we proceed to testing.

## Remediation Steps

### 1. Make the waveform responsive
- Replace the hard-coded `300px` fallback in `Waveform.tsx` with an `onLayout` measurement so bar widths reflect the true container size when `width="100%"`.
- Memoize the calculated container width to avoid layout thrash and keep bar spacing consistent with flexible layouts.
- Update the documentation snippet to describe the responsive behavior and note that the component self-adjusts when the parent resizes.

### 2. Clean up the Skia sample
- Remove the unused `useRef`, `useEffect`, `useCanvasRef`, and `Rect` imports in `WaveformCanvas.tsx`, or demonstrate their use (e.g., caching draw commands) so the snippet passes TypeScript linting out of the box.
- Verify the updated code compiles in both bare React Native and Expo/Skia environments before re-running the docs example.

### 3. Preserve dictation options across permission prompts
- In `DictationModule.startListening`, store the parsed `DictationOptions` alongside the pending `Promise` whenever we have to request `RECORD_AUDIO`.
- After the user grants permission, restart listening with the stored options instead of the current `DictationOptions()` default so features like audio preservation and custom paths are honored on the first attempt.
- Add a regression test that toggles the `preserveAudio` flag and confirms the flag remains true when permission is granted mid-session.

### 4. Harden permission requests when the activity is null
- Guard `requestRecordPermission()` so it either queues the request until an activity is available or immediately rejects the JS promise with a descriptive error when `currentActivity` is null.
- Ensure the pending promise always resolves or rejectsnever leaving JS callers hangingby clearing the stored promise in all control paths (granted, denied, no activity).
- Document this behavior in Phase 8 so integrators know how the module reacts when the app is backgrounded.

### 5. Deliver truthful audio normalization results
- Replace the placeholder implementation of `AudioEncoderManager.normalizeAudio` with a real transcoding/check pipeline (e.g., `MediaExtractor` + `MediaCodec`) that guarantees the output is AAC `.m4a` and reports accurate duration and size.
- Until full normalization ships, clearly document the limitation and avoid returning `durationMs = 0` so downstream logic does not assume the recording is empty.
- Add verification steps that compare the reported duration/size against the actual file metadata to prevent regressions.

## Recommended Order
1. Land the waveform responsiveness fix and Skia sample cleanup (Docs Phase 7).
2. Update `DictationModule` permission handling plus the associated documentation (Docs Phase 8).
3. Implement the real normalization path and its tests, then refresh the docs checklist.

Completing these items keeps the React Native migration instructions aligned with the implemented code and prevents integrators from hitting avoidable runtime failures.

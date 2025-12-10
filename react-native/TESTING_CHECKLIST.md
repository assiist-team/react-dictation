# Manual Testing Checklist

## iOS Testing

### Permissions
- [ ] First launch shows microphone permission dialog
- [ ] First `startListening` shows speech recognition permission dialog
- [ ] Denying permission shows appropriate error
- [ ] Re-granting permission in Settings works

### Audio Engine
- [ ] Recording starts within 100ms of tap
- [ ] Audio level updates at ~30 FPS
- [ ] Waveform responds to voice input
- [ ] Recording continues during interruptions (calls) - verify pause/resume
- [ ] Unplugging headphones stops recording gracefully

### Speech Recognition
- [ ] Partial results appear while speaking
- [ ] Final result appears after stop
- [ ] Long utterances (30+ seconds) work correctly
- [ ] Multiple languages work (if supported)
- [ ] Offline recognition works (when downloaded)

### Audio Preservation
- [ ] Audio file is created after stop
- [ ] Audio file is deleted after cancel (when configured)
- [ ] Audio file contains valid audio
- [ ] File plays back correctly
- [ ] 60-minute limit triggers correctly

### Edge Cases
- [ ] Rapid start/stop doesn't crash
- [ ] Background/foreground transitions work
- [ ] Memory usage stays stable during long sessions
- [ ] Works with Bluetooth audio devices

## Android Testing

### Permissions
- [ ] Runtime permission dialog appears
- [ ] Denying shows error
- [ ] "Don't ask again" scenario handled

### Speech Recognition
- [ ] Google speech recognition works
- [ ] Partial results appear
- [ ] Network errors show appropriate message
- [ ] Works with different OEM implementations

### Audio
- [ ] Audio levels update smoothly
- [ ] Recording produces valid files
- [ ] Works with different sample rates

## Performance Validation

### Latency Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Initialize to ready | < 500ms | Console timestamps |
| Tap to listening | < 100ms | Video frame analysis |
| First partial result | < 500ms | Event timestamp delta |
| Audio level latency | < 50ms | Tap test + video |
| Stop to final result | < 200ms | Console timestamps |

### Memory Benchmarks

| Scenario | Max Memory | Duration |
|----------|------------|----------|
| Idle after init | +10 MB | - |
| During recording | +50 MB | 5 min recording |
| After recording | +15 MB | After cleanup |

## Validation Against Flutter Baseline

Compare results with the original Flutter implementation:

| Feature | Flutter Behavior | RN Behavior | Status |
|---------|------------------|-------------|--------|
| Init latency | ~200ms | ? | ⬜ |
| Start latency | ~80ms | ? | ⬜ |
| Audio level range | 0.0-1.0 | 0.0-1.0 | ⬜ |
| Waveform FPS | 30 | 30 | ⬜ |
| Partial results | ✓ | ? | ⬜ |
| Audio preservation | ✓ | ? | ⬜ |
| Canonical format | AAC-LC 44.1kHz mono 64kbps | ? | ⬜ |
| Duration limit | 60 min | ? | ⬜ |
| Permission handling | ✓ | ? | ⬜ |
| Error codes | Consistent | ? | ⬜ |

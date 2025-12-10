# Testing Documentation

This directory contains comprehensive tests for the React Native Dictation module.

## Test Structure

```
__tests__/
├── DictationService.test.ts      # Unit tests for DictationService
├── hooks/
│   └── useWaveform.test.ts       # Unit tests for useWaveform hook
├── integration/
│   └── DictationIntegration.test.tsx  # Integration tests
└── benchmarks/
    └── latency.test.ts           # Performance benchmarks
```

## Running Tests

### TypeScript/Jest Tests

```bash
# Run all tests
npm test

# Run in watch mode
npm run test:watch

# Run with coverage
npm run test:coverage

# Run specific test file
npm test -- DictationService.test.ts
```

### iOS Native Tests (XCTest)

```bash
# Run iOS tests
npm run test:ios

# Or manually:
cd ios
xcodebuild test -scheme ReactNativeDictation -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Android Native Tests (JUnit)

```bash
# Run Android tests
npm run test:android

# Or manually:
cd android
./gradlew test
```

### E2E Tests (Detox)

```bash
# iOS E2E tests
npm run e2e:ios

# Android E2E tests
npm run e2e:android
```

## Test Coverage

- **Unit Tests**: Test individual components and functions in isolation
- **Integration Tests**: Test component interactions and hook integrations
- **Performance Benchmarks**: Measure latency and memory usage
- **E2E Tests**: Test complete user flows on real devices/simulators

## Manual Testing

See [TESTING_CHECKLIST.md](../TESTING_CHECKLIST.md) for manual testing procedures and validation against Flutter baseline.

## Writing New Tests

### Unit Test Example

```typescript
import { DictationService } from '../src/DictationService';

describe('MyFeature', () => {
  it('should do something', async () => {
    const service = new DictationService();
    // Test implementation
  });
});
```

### Integration Test Example

```typescript
import { renderHook } from '@testing-library/react';
import { useDictation } from '../../src';

describe('Integration', () => {
  it('should work together', () => {
    const { result } = renderHook(() => useDictation());
    // Test integration
  });
});
```

## Performance Benchmarks

Performance benchmarks verify latency targets:
- Initialize: < 500ms
- Start listening: < 100ms
- Audio level: < 50ms
- Stop: < 200ms

Run benchmarks with:
```bash
npm test -- benchmarks/latency.test.ts
```

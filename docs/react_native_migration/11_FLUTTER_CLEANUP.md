# Phase 11: Flutter Cleanup

## Overview

This phase removes all Flutter-specific code, files, and dependencies after the React Native migration is complete. This ensures a clean codebase with no Flutter remnants.

## Prerequisites

- ✅ All React Native migration phases (1-10) are complete
- ✅ React Native module is tested and working
- ✅ You have a backup/commit of the current state

## Cleanup Checklist

### 1. Dart/Flutter Source Files

Delete the following directories and files:

```bash
# Main Flutter plugin code
rm -rf lib/
rm -rf test/

# Flutter example app
rm -rf example/

# Flutter configuration files
rm -f pubspec.yaml
rm -f pubspec.lock
rm -f analysis_options.yaml
rm -f .metadata
```

**Files to delete:**
- `lib/` - All Dart source files (flutter_dictation.dart, services/, widgets/, theme/)
- `test/` - All Dart test files (flutter_dictation_test.dart, benchmarks/, integration/, performance/, services/)
- `example/` - Flutter example app directory
- `pubspec.yaml` - Flutter package configuration
- `pubspec.lock` - Flutter dependency lock file
- `analysis_options.yaml` - Dart analyzer configuration
- `.metadata` - Flutter metadata file

### 2. iOS Flutter Plugin Files

Remove Flutter-specific iOS bridge code:

```bash
# Flutter plugin registration
rm -f ios/Classes/FlutterDictationPlugin.swift

# Flutter-specific manager (replaced by DictationCoordinator)
rm -f ios/Classes/DictationManager.swift

# Flutter podspec
rm -f ios/flutter_dictation.podspec
```

**Files to delete:**
- `ios/Classes/FlutterDictationPlugin.swift` - Flutter plugin registration (replaced by `DictationModule.swift`)
- `ios/Classes/DictationManager.swift` - Flutter-specific coordinator (replaced by `DictationCoordinator.swift`)
- `ios/flutter_dictation.podspec` - Flutter CocoaPods spec (replaced by React Native podspec)

### 3. macOS Flutter Support

Remove macOS Flutter platform support:

```bash
rm -rf macos/
```

**Directory to delete:**
- `macos/` - Entire macOS Flutter platform directory (not needed for React Native)

### 4. Android Flutter Plugin Files

Remove Flutter-specific Android code:

```bash
# Check for Flutter plugin registration in Android
# Typically in android/src/main/kotlin/com/example/flutter_dictation/FlutterDictationPlugin.kt
# If it exists, delete it
```

**Note:** The Android native code should already be migrated to React Native format in Phase 8. Verify no Flutter plugin registration files remain.

### 5. Clean Up Native Code References

Remove Flutter imports and references from native Swift files:

#### `ios/Classes/AudioEngineManager.swift`

Remove or update Flutter-specific comments:

```swift
// Find and remove/update:
// "Comprehensive logging function that ensures logs are visible in both Xcode and Flutter console."
// Replace with:
// "Comprehensive logging function that ensures logs are visible in Xcode console."
```

#### `ios/Classes/CanonicalAudioStorage.swift`

Update folder name reference:

```swift
// Change:
private static let recordingsFolderName = "FlutterDictationRecordings"

// To:
private static let recordingsFolderName = "ReactNativeDictationRecordings"
```

### 6. Update .gitignore

Ensure `.gitignore` no longer includes Flutter-specific patterns (or keep them if you want to ignore them):

```gitignore
# Flutter/Dart/Pub related
**/doc/api/
**/ios/Flutter/.last_build_id
.dart_tool/
.flutter-plugins
.flutter-plugins-dependencies
.packages
.pub-cache/
.pub/
/build/

# Remove or comment out if no longer needed:
# **/ios/Flutter/Flutter.framework
# **/ios/Flutter/Flutter.podspec
```

### 7. Update README.md

Update the main `README.md` to remove Flutter references:

- Remove Flutter installation instructions
- Remove Flutter example usage
- Update to React Native installation/usage only
- Update badges/logos if they reference Flutter

### 8. Clean Build Artifacts

Remove Flutter build artifacts:

```bash
# Flutter build directories
rm -rf build/
rm -rf .dart_tool/
rm -rf .flutter-plugins
rm -rf .flutter-plugins-dependencies
rm -rf .packages

# iOS Flutter artifacts (if any)
rm -rf ios/Flutter/
rm -rf ios/.symlinks/
rm -rf ios/Pods/Flutter/

# Android Flutter artifacts (if any)
rm -rf android/.gradle/
rm -rf android/app/build/
```

### 9. Verify No Flutter Dependencies

Check for any remaining Flutter references:

```bash
# Search for Flutter imports in native code
grep -r "import Flutter" ios/ android/

# Search for FlutterMethodChannel, FlutterEventChannel, etc.
grep -r "FlutterMethodChannel\|FlutterEventChannel\|FlutterResult\|FlutterPlugin" ios/ android/

# Search for Flutter in package.json (shouldn't exist)
grep -i "flutter" package.json
```

### 10. Update iOS Podfile (if needed)

If the iOS `Podfile` references Flutter, remove those references:

```ruby
# Remove lines like:
# platform :ios, '13.0'
# use_frameworks!
# use_modular_headers!

# Flutter-specific pods
# pod 'Flutter', :path => '../flutter'

# Keep only React Native pods
```

### 11. Clean Xcode Project

Remove Flutter-related files from Xcode project:

1. Open `ios/Runner.xcworkspace` (or `.xcodeproj`) in Xcode
2. Remove `FlutterDictationPlugin.swift` from project navigator
3. Remove `DictationManager.swift` from project navigator
4. Remove `flutter_dictation.podspec` if it's referenced
5. Clean build folder: Product → Clean Build Folder (⇧⌘K)

### 12. Verify React Native Module Works

After cleanup, verify the React Native module still works:

```bash
# iOS
cd ios && pod install && cd ..
npx react-native run-ios

# Android
npx react-native run-android
```

## Post-Cleanup Verification

Run these checks to ensure cleanup was successful:

### ✅ Checklist

- [ ] No `.dart` files remain in the repository
- [ ] No `pubspec.yaml` or Flutter config files remain
- [ ] No `FlutterDictationPlugin.swift` or `DictationManager.swift` files
- [ ] No `flutter_dictation.podspec` file
- [ ] No `macos/` directory
- [ ] No Flutter imports in native code (`grep -r "import Flutter"` returns nothing)
- [ ] React Native module builds and runs successfully
- [ ] All tests pass (React Native tests, not Flutter tests)
- [ ] README.md updated with React Native-only instructions

### Search Commands

```bash
# Find any remaining Dart files
find . -name "*.dart" -not -path "./node_modules/*" -not -path "./.git/*"

# Find any remaining Flutter references
grep -r "Flutter" --include="*.swift" --include="*.m" --include="*.kt" --include="*.java" ios/ android/ react-native/

# Find any remaining pubspec files
find . -name "pubspec.yaml" -not -path "./node_modules/*" -not -path "./.git/*"
```

## Rollback Plan

If you need to rollback the cleanup:

1. Restore from git commit before cleanup:
   ```bash
   git checkout <commit-before-cleanup> -- lib/ test/ example/ pubspec.yaml ios/Classes/FlutterDictationPlugin.swift ios/Classes/DictationManager.swift ios/flutter_dictation.podspec macos/
   ```

2. Or restore entire project from backup

## Notes

- **Keep native managers**: The Swift files `AudioEngineManager.swift`, `SpeechRecognizerManager.swift`, `AudioEncoderManager.swift`, `AudioPreservation.swift`, and `CanonicalAudioStorage.swift` should be kept as they're framework-agnostic and used by the React Native module.

- **Keep iOS project structure**: The `ios/Runner.xcworkspace` and related Xcode project files should remain, but Flutter-specific files should be removed.

- **Android**: The Android native code should already be migrated in Phase 8. Just verify no Flutter plugin registration remains.

## Timeline

- **Estimated time**: 30-60 minutes
- **Risk level**: Low (if you have a git commit/backup)
- **Dependencies**: All React Native migration phases (1-10) must be complete

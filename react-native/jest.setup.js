// Jest setup file to mock React Native before tests run
// This prevents Babel transform issues with react-native's Flow syntax
// Note: We create a complete mock without requiring the actual module to avoid Babel parsing issues

jest.mock('react-native', () => {
  // Create a complete mock without requiring actual react-native
  // This avoids Babel trying to parse react-native's Flow syntax
  return {
    NativeModules: {
      DictationModule: {
        initialize: jest.fn().mockResolvedValue(undefined),
        startListening: jest.fn().mockResolvedValue(undefined),
        stopListening: jest.fn().mockResolvedValue(undefined),
        cancelListening: jest.fn().mockResolvedValue(undefined),
        getAudioLevel: jest.fn().mockResolvedValue(0.5),
        normalizeAudio: jest.fn().mockResolvedValue({
          canonicalPath: '/path/to/normalized.m4a',
          durationMs: 5000,
          sizeBytes: 40000,
          wasReencoded: false,
        }),
      },
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => ({
      addListener: jest.fn().mockReturnValue({ remove: jest.fn() }),
    })),
    Platform: {
      OS: 'ios',
      select: jest.fn((obj) => obj.ios || obj.default),
      Version: 17,
    },
    processColor: jest.fn((color) => color),
    // Add other commonly used React Native exports that might be needed
    StyleSheet: {
      create: jest.fn((styles) => styles),
      flatten: jest.fn(),
      hairlineWidth: 0.5,
    },
    View: (props) => require('react').createElement('View', props),
    Text: (props) => require('react').createElement('Text', props),
    ScrollView: (props) => require('react').createElement('ScrollView', props),
    Touchable: {
      Mixin: {
        touchableHandleStartShouldSetResponder: jest.fn(),
        touchableHandleResponderTerminationRequest: jest.fn(),
        touchableHandleResponderGrant: jest.fn(),
        touchableHandleResponderMove: jest.fn(),
        touchableHandleResponderRelease: jest.fn(),
        touchableHandleResponderTerminate: jest.fn(),
      },
    },
    TouchableOpacity: 'TouchableOpacity',
    TouchableHighlight: 'TouchableHighlight',
    TouchableWithoutFeedback: 'TouchableWithoutFeedback',
    TextInput: 'TextInput',
    Image: 'Image',
    Animated: {
      Value: jest.fn(),
      ValueXY: jest.fn(),
      timing: jest.fn(),
      spring: jest.fn(),
      decay: jest.fn(),
      sequence: jest.fn(),
      parallel: jest.fn(),
      stagger: jest.fn(),
      loop: jest.fn(),
      event: jest.fn(),
      createAnimatedComponent: jest.fn((component) => component),
    },
  };
});

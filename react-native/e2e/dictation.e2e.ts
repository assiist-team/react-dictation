import { device, element, by, expect, waitFor } from 'detox';

describe('Dictation E2E', () => {
  beforeAll(async () => {
    await device.launchApp({ 
      permissions: { 
        microphone: 'YES',
        speechRecognition: 'YES'
      } 
    });
  });

  beforeEach(async () => {
    await device.reloadReactNative();
  });

  it('should show mic button', async () => {
    await expect(element(by.id('mic-button'))).toBeVisible();
  });

  it('should start listening on mic tap', async () => {
    await element(by.id('mic-button')).tap();
    await expect(element(by.id('waveform'))).toBeVisible();
    await expect(element(by.id('cancel-button'))).toBeVisible();
  });

  it('should stop on checkmark tap', async () => {
    await element(by.id('mic-button')).tap();
    await waitFor(element(by.id('stop-button')))
      .toBeVisible()
      .withTimeout(2000);
    await element(by.id('stop-button')).tap();
    await expect(element(by.id('waveform'))).not.toBeVisible();
  });

  it('should cancel on X tap', async () => {
    await element(by.id('mic-button')).tap();
    await element(by.id('cancel-button')).tap();
    await expect(element(by.id('waveform'))).not.toBeVisible();
  });

  it('should show waveform during recording', async () => {
    await element(by.id('mic-button')).tap();
    
    // Wait for waveform to appear
    await waitFor(element(by.id('waveform')))
      .toBeVisible()
      .withTimeout(2000);
    
    // Waveform should be visible and updating
    await expect(element(by.id('waveform'))).toBeVisible();
  });

  it('should handle rapid start/stop', async () => {
    // Rapidly start and stop multiple times
    for (let i = 0; i < 3; i++) {
      await element(by.id('mic-button')).tap();
      await waitFor(element(by.id('stop-button')))
        .toBeVisible()
        .withTimeout(1000);
      await element(by.id('stop-button')).tap();
      await waitFor(element(by.id('mic-button')))
        .toBeVisible()
        .withTimeout(1000);
    }
  });
});

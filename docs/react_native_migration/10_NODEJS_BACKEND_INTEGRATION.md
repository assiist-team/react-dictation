# Phase 10: Node.js Backend Integration

## Overview

This phase covers patterns for integrating the React Native dictation module with a Node.js backend, including audio file upload, processing, and real-time transcription alternatives.

## Architecture Options

### Option 1: Client-Side Dictation (Current Module)

```
┌─────────────────────────────────────────────────────────────────┐
│ React Native App                                                │
│                                                                 │
│  ┌────────────────────┐   ┌─────────────────────┐               │
│  │ Dictation Module   │   │ Audio File          │               │
│  │ (On-Device Speech) │──▶│ (.m4a)              │               │
│  └────────────────────┘   └──────────┬──────────┘               │
│           │                          │                          │
│           │ transcription            │ upload                   │
│           ▼                          ▼                          │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    API Layer                               │ │
│  └────────────────────────────────────┬───────────────────────┘ │
└───────────────────────────────────────┼─────────────────────────┘
                                        │
                                        ▼
┌───────────────────────────────────────────────────────────────────┐
│ Node.js Backend                                                   │
│                                                                   │
│  ┌────────────────┐   ┌─────────────────┐   ┌─────────────────┐   │
│  │ Upload Handler │──▶│ Storage (S3)    │──▶│ Database        │   │
│  └────────────────┘   └─────────────────┘   └─────────────────┘   │
│                                                                   │
│  Optional: Re-transcription with Whisper/AssemblyAI               │
└───────────────────────────────────────────────────────────────────┘
```

### Option 2: Server-Side Transcription

```
┌─────────────────────────────────────────────────────────────────┐
│ React Native App                                                │
│                                                                 │
│  ┌────────────────────┐                                         │
│  │ Audio Recording    │ Stream audio chunks                     │
│  │ (No Speech Recog)  │────────────────────────────────────────┐│
│  └────────────────────┘                                        ││
└────────────────────────────────────────────────────────────────┼┘
                                                                 │
                                                                 ▼
┌───────────────────────────────────────────────────────────────────┐
│ Node.js Backend (WebSocket)                                       │
│                                                                   │
│  ┌────────────────────┐   ┌─────────────────────────────────────┐ │
│  │ WebSocket Server   │──▶│ Transcription Service               │ │
│  │ (Audio Chunks)     │   │ (Whisper/Deepgram/AssemblyAI)       │ │
│  └────────────────────┘   └──────────────────┬──────────────────┘ │
│                                              │                    │
│                                              ▼                    │
│                                    ┌─────────────────────────┐    │
│                                    │ Stream results back     │    │
│                                    │ to client               │    │
│                                    └─────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
```

## Implementation: Option 1 (Recommended)

### React Native API Layer

**src/api/dictation.ts**
```typescript
import { Platform } from 'react-native';
import { DictationAudioFile, NormalizedAudioResult } from '../types';

const API_BASE_URL = process.env.API_URL || 'http://localhost:3000';

interface UploadAudioResponse {
  id: string;
  url: string;
  durationMs: number;
  transcription?: string;
}

interface CreateDictationRequest {
  transcription: string;
  audioFile?: DictationAudioFile;
  metadata?: Record<string, any>;
}

interface CreateDictationResponse {
  id: string;
  transcription: string;
  audioUrl?: string;
  createdAt: string;
}

/**
 * Upload audio file to backend storage
 */
export async function uploadAudioFile(
  file: DictationAudioFile,
  authToken: string
): Promise<UploadAudioResponse> {
  const formData = new FormData();
  
  // Create file blob from path
  formData.append('audio', {
    uri: Platform.OS === 'ios' ? `file://${file.path}` : file.path,
    type: 'audio/mp4',
    name: file.path.split('/').pop() || 'recording.m4a',
  } as any);
  
  formData.append('durationMs', String(file.durationMs));
  formData.append('sampleRate', String(file.sampleRate));
  formData.append('channelCount', String(file.channelCount));

  const response = await fetch(`${API_BASE_URL}/api/audio/upload`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${authToken}`,
      'Content-Type': 'multipart/form-data',
    },
    body: formData,
  });

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.message || 'Failed to upload audio');
  }

  return response.json();
}

/**
 * Create a dictation entry with transcription and optional audio
 */
export async function createDictation(
  data: CreateDictationRequest,
  authToken: string
): Promise<CreateDictationResponse> {
  const response = await fetch(`${API_BASE_URL}/api/dictations`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${authToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(data),
  });

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.message || 'Failed to create dictation');
  }

  return response.json();
}

/**
 * Get re-transcription from server (e.g., using Whisper)
 */
export async function getServerTranscription(
  audioUrl: string,
  authToken: string
): Promise<{ transcription: string }> {
  const response = await fetch(`${API_BASE_URL}/api/audio/transcribe`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${authToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ audioUrl }),
  });

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.message || 'Failed to transcribe audio');
  }

  return response.json();
}
```

### Usage in Component

**src/screens/DictationScreen.tsx**
```typescript
import React, { useState, useEffect } from 'react';
import { View, TextInput, Alert } from 'react-native';
import { useDictation, useWaveform, AudioControlsDecorator } from 'react-native-dictation';
import { uploadAudioFile, createDictation } from '../api/dictation';
import { useAuth } from '../hooks/useAuth';

export function DictationScreen() {
  const { token } = useAuth();
  const [text, setText] = useState('');
  const [isUploading, setIsUploading] = useState(false);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  
  const waveform = useWaveform();
  
  const dictation = useDictation({
    onFinalResult: (finalText) => {
      setText((prev) => `${prev}${finalText} `);
    },
    onAudioFile: async (audioFile) => {
      // Upload audio file after recording stops
      if (audioFile && !audioFile.wasCancelled && token) {
        setIsUploading(true);
        try {
          const uploadResult = await uploadAudioFile(audioFile, token);
          console.log('Audio uploaded:', uploadResult.url);
          
          // Create dictation entry
          await createDictation({
            transcription: text,
            audioFile,
            metadata: {
              audioUrl: uploadResult.url,
              audioId: uploadResult.id,
            },
          }, token);
          
          Alert.alert('Success', 'Dictation saved!');
        } catch (error) {
          console.error('Upload failed:', error);
          Alert.alert('Error', 'Failed to save dictation');
        } finally {
          setIsUploading(false);
        }
      }
    },
    sessionOptions: {
      preserveAudio: true,
      deleteAudioIfCancelled: true,
    },
  });

  // ... rest of component
}
```

### Node.js Backend

**server/routes/audio.ts**
```typescript
import express from 'express';
import multer from 'multer';
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { v4 as uuidv4 } from 'uuid';
import { authMiddleware } from '../middleware/auth';
import { db } from '../db';

const router = express.Router();

// Configure S3
const s3Client = new S3Client({
  region: process.env.AWS_REGION,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
  },
});

// Configure multer for file uploads
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 50 * 1024 * 1024, // 50MB max (matches canonical format limit)
  },
  fileFilter: (req, file, cb) => {
    // Accept audio files
    if (file.mimetype.startsWith('audio/')) {
      cb(null, true);
    } else {
      cb(new Error('Only audio files are allowed'));
    }
  },
});

// Upload audio file
router.post('/upload', authMiddleware, upload.single('audio'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No audio file provided' });
    }

    const userId = req.user.id;
    const fileId = uuidv4();
    const key = `audio/${userId}/${fileId}.m4a`;

    // Upload to S3
    await s3Client.send(new PutObjectCommand({
      Bucket: process.env.S3_BUCKET!,
      Key: key,
      Body: req.file.buffer,
      ContentType: 'audio/mp4',
      Metadata: {
        userId,
        durationMs: req.body.durationMs,
        sampleRate: req.body.sampleRate,
        channelCount: req.body.channelCount,
      },
    }));

    // Generate signed URL for access
    const url = await getSignedUrl(s3Client, new GetObjectCommand({
      Bucket: process.env.S3_BUCKET!,
      Key: key,
    }), { expiresIn: 3600 * 24 * 7 }); // 7 days

    // Save to database
    const audioRecord = await db.audio.create({
      data: {
        id: fileId,
        userId,
        s3Key: key,
        durationMs: parseFloat(req.body.durationMs) || 0,
        sampleRate: parseFloat(req.body.sampleRate) || 44100,
        channelCount: parseInt(req.body.channelCount) || 1,
        fileSizeBytes: req.file.size,
      },
    });

    res.json({
      id: audioRecord.id,
      url,
      durationMs: audioRecord.durationMs,
    });
  } catch (error) {
    console.error('Upload error:', error);
    res.status(500).json({ error: 'Failed to upload audio' });
  }
});

// Transcribe audio using Whisper API
router.post('/transcribe', authMiddleware, async (req, res) => {
  try {
    const { audioUrl } = req.body;

    if (!audioUrl) {
      return res.status(400).json({ error: 'Audio URL required' });
    }

    // Example: Using OpenAI Whisper API
    const OpenAI = require('openai');
    const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

    // Download audio from S3
    const audioResponse = await fetch(audioUrl);
    const audioBlob = await audioResponse.blob();

    // Create form data for Whisper
    const formData = new FormData();
    formData.append('file', audioBlob, 'audio.m4a');
    formData.append('model', 'whisper-1');

    const transcription = await openai.audio.transcriptions.create({
      file: audioBlob,
      model: 'whisper-1',
    });

    res.json({
      transcription: transcription.text,
    });
  } catch (error) {
    console.error('Transcription error:', error);
    res.status(500).json({ error: 'Failed to transcribe audio' });
  }
});

export default router;
```

**server/routes/dictations.ts**
```typescript
import express from 'express';
import { authMiddleware } from '../middleware/auth';
import { db } from '../db';

const router = express.Router();

// Create dictation
router.post('/', authMiddleware, async (req, res) => {
  try {
    const { transcription, audioFile, metadata } = req.body;
    const userId = req.user.id;

    const dictation = await db.dictation.create({
      data: {
        userId,
        transcription,
        audioId: metadata?.audioId,
        audioUrl: metadata?.audioUrl,
        durationMs: audioFile?.durationMs,
        metadata: metadata ? JSON.stringify(metadata) : null,
      },
    });

    res.json({
      id: dictation.id,
      transcription: dictation.transcription,
      audioUrl: dictation.audioUrl,
      createdAt: dictation.createdAt.toISOString(),
    });
  } catch (error) {
    console.error('Create dictation error:', error);
    res.status(500).json({ error: 'Failed to create dictation' });
  }
});

// List dictations
router.get('/', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { limit = 20, offset = 0 } = req.query;

    const dictations = await db.dictation.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: Number(limit),
      skip: Number(offset),
    });

    res.json({ dictations });
  } catch (error) {
    console.error('List dictations error:', error);
    res.status(500).json({ error: 'Failed to list dictations' });
  }
});

export default router;
```

### Database Schema (Prisma)

**prisma/schema.prisma**
```prisma
model User {
  id         String      @id @default(cuid())
  email      String      @unique
  createdAt  DateTime    @default(now())
  audio      Audio[]
  dictations Dictation[]
}

model Audio {
  id           String      @id @default(cuid())
  userId       String
  user         User        @relation(fields: [userId], references: [id])
  s3Key        String
  durationMs   Float
  sampleRate   Float       @default(44100)
  channelCount Int         @default(1)
  fileSizeBytes Int
  createdAt    DateTime    @default(now())
  dictations   Dictation[]

  @@index([userId])
}

model Dictation {
  id            String   @id @default(cuid())
  userId        String
  user          User     @relation(fields: [userId], references: [id])
  transcription String   @db.Text
  audioId       String?
  audio         Audio?   @relation(fields: [audioId], references: [id])
  audioUrl      String?
  durationMs    Float?
  metadata      String?  @db.Text
  createdAt     DateTime @default(now())
  updatedAt     DateTime @updatedAt

  @@index([userId])
  @@index([audioId])
}
```

## API Endpoints Summary

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/audio/upload` | POST | Upload audio file to S3 |
| `/api/audio/transcribe` | POST | Re-transcribe audio with Whisper |
| `/api/dictations` | POST | Create dictation entry |
| `/api/dictations` | GET | List user's dictations |
| `/api/dictations/:id` | GET | Get single dictation |
| `/api/dictations/:id` | DELETE | Delete dictation |

## Environment Variables

```bash
# Node.js Backend
PORT=3000
DATABASE_URL="postgresql://..."
JWT_SECRET="your-secret"

# AWS S3
AWS_REGION="us-east-1"
AWS_ACCESS_KEY_ID="..."
AWS_SECRET_ACCESS_KEY="..."
S3_BUCKET="your-dictation-bucket"

# OpenAI (for Whisper)
OPENAI_API_KEY="sk-..."
```

## Verification Checklist

- [ ] Audio upload works with canonical .m4a format
- [ ] S3 storage configured correctly
- [ ] Database schema matches API needs
- [ ] Auth middleware protects routes
- [ ] Error handling covers edge cases
- [ ] Transcription service integrates properly

## Security Considerations

1. **Authentication**: All endpoints require valid JWT
2. **File Validation**: Only accept audio MIME types
3. **Size Limits**: 50MB matches client-side limit
4. **Signed URLs**: S3 URLs expire after 7 days
5. **User Isolation**: Users can only access their own data

## Summary

This completes the React Native Dictation Module migration plan. The module provides:

1. **Low-latency dictation** using native iOS `SFSpeechRecognizer` and Android `SpeechRecognizer`
2. **Real-time waveform** visualization at 30 FPS
3. **Audio preservation** in canonical AAC format
4. **TypeScript-first** API with React hooks
5. **Node.js integration** patterns for backend storage and optional re-transcription

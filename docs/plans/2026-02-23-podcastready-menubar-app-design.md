# PodcastReady — macOS Menubar App Design

**Date:** 2026-02-23
**Status:** Approved

## Problem

Before each podcast recording session, the host needs to verify their video setup (lighting, framing, color temperature, background) is consistent and professional. Currently this requires manual visual comparison or asking someone for feedback. A small native tool that uses AI vision to analyze the setup and give actionable feedback would streamline this pre-recording ritual.

## Solution

A native macOS SwiftUI menubar app that shows a live camera preview and uses the Anthropic Claude Vision API to analyze the current setup against podcast video best practices.

## User Experience Flow

1. Click the menubar icon (camera icon) before recording
2. Popover opens showing live camera feed
3. Click "Analyze Setup"
4. App captures a frame, sends to Claude Vision, shows loading state
5. Results appear as a scored checklist:
   - **Lighting** — brightness, evenness, shadows
   - **Color Temperature** — warm/cool balance, skin tone
   - **Framing** — head position, eye level, headroom
   - **Background** — distractions, clutter, color consistency
6. Each category gets a status (Good / Needs Adjustment) with a specific suggestion
7. Make adjustments, click "Analyze" again to re-check
8. Close popover and start recording

## Architecture

```
┌─────────────────────────────┐
│  Menubar Icon (NSStatusItem)│
└──────────┬──────────────────┘
           │ click
┌──────────▼──────────────────┐
│  Popover (SwiftUI)          │
│  ┌───────────────────────┐  │
│  │  Live Camera Preview  │  │
│  │  (AVCaptureSession)   │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │  [Analyze Setup] btn  │  │
│  └───────────┬───────────┘  │
│              │ capture frame │
│  ┌───────────▼───────────┐  │
│  │  Claude Vision API    │  │
│  │  (Anthropic Swift SDK)│  │
│  └───────────┬───────────┘  │
│  ┌───────────▼───────────┐  │
│  │  Results Checklist    │  │
│  │  - Lighting ✓/⚠       │  │
│  │  - Color Temp ✓/⚠     │  │
│  │  - Framing ✓/⚠        │  │
│  │  - Background ✓/⚠     │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │  [⚙ Settings]        │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

## Key Components

| Component | Tech | Purpose |
|-----------|------|---------|
| `PodcastReadyApp` | SwiftUI App lifecycle | Menubar-only app (no dock icon) |
| `CameraManager` | AVFoundation | Camera session, frame capture |
| `CameraPreviewView` | NSViewRepresentable | Live preview in SwiftUI |
| `AnalysisService` | Anthropic Swift SDK | Sends frame to Claude, parses response |
| `AnalysisResultView` | SwiftUI | Displays scored checklist |
| `SettingsView` | SwiftUI | API key input, camera selection |

## AI Prompt Strategy

The app sends a captured JPEG frame to Claude with a system prompt:

"You are a podcast video setup analyst. Evaluate this webcam frame for podcast recording quality. Score each category as GOOD or NEEDS_ADJUSTMENT with a brief specific suggestion. Categories: Lighting (brightness, evenness, shadows), Color Temperature (warm/cool, skin tone), Framing (head position, eye level, headroom, rule of thirds), Background (distractions, clutter, evenness). Return JSON."

Response is parsed into structured `AnalysisResult` for the UI.

## Settings

- **API Key** — stored in macOS Keychain (secure)
- **Camera selection** — dropdown of available cameras
- **Launch at login** — optional toggle

## Technical Decisions

- **Platform:** macOS only, menubar app (no dock icon)
- **UI Framework:** SwiftUI
- **Camera:** AVFoundation (AVCaptureSession)
- **AI Provider:** Anthropic Claude Vision API via Swift SDK
- **Secrets:** macOS Keychain for API key storage
- **Minimum macOS:** 14.0 (Sonoma) for latest SwiftUI features
- **Distribution:** Direct download / local build (no App Store)

## Approach

Pure SwiftUI menubar app chosen over hybrid (WebView) and CLI approaches for:
- Native camera access via AVFoundation
- Lightweight footprint (~5MB)
- macOS-native permissions flow
- Single tech stack (Swift only)

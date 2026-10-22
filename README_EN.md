# 🚀 QLaunch (BiKing567 Maintenance Fork)

[English](README_EN.md) | [简体中文](readme.md)

<div align="center">
  <img src="web/icons/qlaunchpad-512.png" width="128" alt="QLaunch">
</div>

---

<p align="center">
  A clean, high-performance macOS Launchpad replacement. Designer-grade high-fidelity icon rendering, 120Hz high refresh rate, liquid glass styling, and silky smooth transition animations.
</p>

<p align="center">
  <b>This branch is based on <a href="https://github.com/qzrzz/QLaunch">qzrzz/QLaunch</a>, featuring deep refactorings and optimizations for trackpad gestures, animation continuity, and stability.</b>
</p>

- 📦 **Download Latest Release**: [BiKing567/QLaunch Releases (V1.2.0)](https://github.com/BiKing567/QLaunch/releases)
- 🏠 **Original Project Homepage**: [https://qzrzz.com/QLaunch/](https://qzrzz.com/QLaunch/)
- 🔗 **Original Project Repository**: [https://github.com/qzrzz/QLaunch](https://github.com/qzrzz/QLaunch)

<table>
  <tr>
    <td><img src="web/assets/s1.png" alt="QLaunch" width="100%"></td>
    <td><img src="web/assets/s2.png" alt="QLaunch" width="100%"></td>
  </tr>
</table>

## 🌟 Key Improvements & Features in this Fork

Built upon the excellent foundation of the original QLaunch, this fork deeply addresses multi-finger trackpad gestures, micro-interaction animation details, and system compatibility:

### 🪟 Native Liquid Glass Folders & Icon Sizing (V1.2.0)
- **Native macOS Liquid Glass Folders**: Rebuilt using system `NSGlassEffectView` & `NSGlassEffectContainerView` hybrid architecture, delivering authentic optical refraction and continuous curvature frosted glass aesthetics.
- **5-Tier Icon Size Slider**: Fully decoupled icon dimensions from grid layouts, offering a 5-step discrete slider from 64pt to 192pt with safety bounds clamping for small screens.
- **Show Dock in Launchpad**: Window level accurately positioned under system Dock with automatic multi-screen safe insets adaptation and seamless drag collision handling.
- **Zero-Churn Rendering Performance**: Eliminated redundant Metal offscreen folder baking; introduced 32pt quantized preview caching and active working set protection to eradicate cache thrashing across massive canvas setups.

### 🖐️ Native Multi-Finger Gestures & System Conflict Prevention
- **System Launchpad & Spotlight Preemption Blocked**: Intercepts and overrides macOS system-level Spotlight FluidGesture and global Launchpad gestures, completely fixing issues where native Spotlight or the system Launchpad would pop up alongside QLaunch during four-finger pinches.
- **Conflict-Free Exit Gesture**: Supports natural spread-out gesture to dismiss when presented, resolving conflicts with macOS "Show Desktop"; optimizes pinch-in logic to avoid false triggers.
- **Smooth Interruption & Dynamic Takeover**: Eliminates dropped gestures during finishing animations. Starting a new pinch while a prior gesture is finishing immediately takes over interaction, making rapid continuous gestures responsive and lag-free.
- **Sleep & Wake Recovery**: Automatically reconnects trackpad and hot corner event listeners after system wake-from-sleep, preventing gesture listener drops after extended sleep.

### 🎬 Animation & Visual Polish
- **Flicker-Free Cancellation**: Thoroughly fixes a visual bug where cancelling an interactive presentation caused content to flash at 100% brightness right before the window was hidden (verified across all 5 animation styles: Fly, Classic, Zoom, Fade, and None).
- **Natural Animation Rhythm**: Resolves double-easing acceleration bugs, restoring natural, silky-smooth native transitions.
- **Strictly Follows User Preferences**: Trackpad entrance/exit animations strictly follow the selected animation style in settings (Fly, Classic, Zoom, Fade, None), removing forced default fly-in behavior.
- **Double-Trigger Prevention**: Fixes rare stutter caused by duplicate animation triggers during pinch-to-open.

### 🔄 Standalone Updates & Refined UI
- **Direct GitHub Releases Update Checker**: Checks for new versions directly via GitHub Releases API, with both silent background checks and manual check dialogs.
- **Redesigned About Entry**: GitHub row features a native card row and pop-up menu for quick navigation to both the upstream author repository and this maintenance fork.

---

## A Note from the Original Author

I have always loved the full-screen icon grid aesthetic of Launchpad. After macOS started neglecting it, I searched for alternatives, but none truly met expectations.

Some were unpolished, others bloated with too many features that ruined the core experience. LaunchNext felt laggy, while LaunchOS, though feature-rich, occasionally stuttered and suffered from blurry icons.

So I decided to create a Launchpad that is smooth, razor-sharp, simple, and delightful.

That is QLaunch.

## Features

- Native Metal rendering
- Designer-grade high-fidelity icon display
- Multiple transition animation styles (Fly, Classic, Zoom, Fade, None)
- Pinyin & fuzzy app search
- Native trackpad multi-finger gestures & hot corner triggers
- App folders support

## Performance

QLaunch strives for designer-grade icon quality and instantaneous responsiveness. Display P3 16-bit high-precision icons are rendered with precision. Since maximum fidelity uses more memory, three performance profiles are available:

| Profile | 😍 Quality First | 😀 Performance First | 🙂 Low Memory |
| --- | --- | --- | --- |
| Icon Textures | float16 4× supersampling | RGBA8 2× supersampling | RGBA8 2× supersampling |
| Screen Buffers | float16 ×3 | bgra8Unorm ×3 | bgra8Unorm ×2 |
| Text Atlas | 2048px float16 | 2048px RGBA8 | RGBA8 |
| Page Resident | All pages | All pages | Current page ±1 |

## Building & Development

Requires Xcode, macOS 14+ SDK, and Bun / Deno:

```sh
bun install
bun run dev               # Build Debug .app and run in foreground
bun run debug             # Build Debug .app and open with Instruments
bun run debug -- --record # Same as above, recording directly with xctrace Time Profiler
bun run build             # Build Release .app, DMG, ZIP (no publish)
bun run release           # Sign, notarize, and publish via QRls
bun run clean             # Clean build artifacts
bun run check             # Validate Swift Package structure
bun run layout:export     # Export current icon grid order / folders / hidden list as JSON
bun run layout:import     # Import layout JSON (default merge; test with --dry-run --strict)
bun run layout:validate   # Validate layout JSON schema
```

### Architecture

```
AppDelegate          NSPanel lifecycle, hotkeys, status bar, gesture dispatch, fade presentation
LaunchpadContainer   Background + Metal grid + SwiftUI overlay
DesktopBackground    CIGaussianBlur dynamic wallpaper
LaunchpadMetalView   Instanced icon/label rendering, DisplayLink animation, page turning
AppStore             Catalog scan, search, pagination state machine, presentation state
Updater              GitHub Releases update checks and notifications
```

### Website

Product website is located in `web/` (Vite + React + TypeScript, multilingual SEO, builds to `docs/` for GitHub Pages).

```sh
cd web
bun install
bun run dev               # Local preview
bun run build             # Build and sync to ../docs (en + zh-Hans)
```

See [web/README.md](web/README.md) for details.

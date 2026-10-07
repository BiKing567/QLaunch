# QLaunch Design System

## 1. Atmosphere & Identity

QLaunch is a quiet, full-screen macOS surface that lets the desktop remain
present while the application grid comes forward. Its signature is layered
translucency: a captured desktop or image sits under a restrained dark tint,
vignette, and Liquid Glass controls so the icons stay readable without losing
place.

## 2. Color

The app uses AppKit semantic colors instead of a second hard-coded palette.

| Role | Existing token | Usage |
|---|---|---|
| Settings surface | `underPageBackgroundColor` | Sidebar background |
| Settings content | `windowBackgroundColor` | Main settings pane |
| Primary text | SwiftUI `.primary` / AppKit label color | Titles and controls |
| Secondary text | SwiftUI `.secondary` | Details and hints |
| Separator | AppKit `separatorColor` | Dividers and field rims |
| Background tint | black at `0.16` alpha (`0.30` on Increase Contrast, `0.85` on Reduce Transparency) | Keeps icons and labels legible over imagery without overpowering acrylic luminosity |
| Background blur | Adjustable radius `0...100`, scaled to 50% for a translucent acrylic blur (~20-24pt) | Softens every background mode while keeping underlying silhouettes visible |
| Acrylic veil | translucent white at `0.02` alpha | Adds a subtle frosted milky glass sheen across all background modes (disabled on Reduce Transparency) |
| Acrylic noise | 128px micro-grain pattern dynamically scaled to backing factor (1:1 physical pixel) at `0.03` opacity | Eliminates color banding and adds tactile frosted-glass texture (disabled on Reduce Transparency) |
| Background vignette | black at `0.22` (bottom) / `0.14` (top) alpha | Adds subtle edge depth to the launch surface |
| Glass control | white with state-dependent opacity | Search, folder title, and drop zone |

New background modes reuse the same tint and vignette. They do not introduce a
new accent color.

## 3. Typography

The native macOS system font is the only family. Settings uses SwiftUI
`.headline`, `.body`, and `.caption`; the launch surface uses the system font
with a 16pt medium search field and atlas-rendered labels. CJK strings remain
localized through `Localizable.strings` and may wrap naturally in the settings
form.

## 4. Spacing & Layout

Spacing follows a compact 4pt rhythm. Existing anchors are the contract:

- Settings sidebar: 140pt wide, window minimum 530×550pt.
- Settings header: 38pt high with 16pt horizontal padding.
- Launch search field: 320×38pt, 36pt from the top, with a larger hit pad.
- Page indicator: 36pt from the bottom with a 24pt vertical hit slop.
- Form rows use native grouped-form spacing and controls.

The background is a full-bleed layer behind Metal and SwiftUI. All background modes
(Wallpaper, Custom image, and Current screen) share the 50% blur scale for a consistent
~20-24pt translucent acrylic blur. For static images (Wallpaper and Custom image), the
blur radius is dynamically normalized by screen point width to ensure identical
on-screen blur across all wallpaper resolutions. Current Screen uses the native
full-screen UI WindowServer material behind the transparent panel, so it needs no
screen-capture authorization. The acrylic veil adapts subtly to system appearance (0.02 in
both dark and light mode), accompanied by a 1:1 pixel grain texture, dark tint (0.16),
and subtle vignette to guarantee WCAG readability for white icon labels. Full accessibility
support is built-in: Reduce Transparency disables the veil and noise while elevating tint
to 0.85; Increase Contrast raises tint to 0.30.

## 5. Components

### Settings sidebar and grouped form

- **Structure:** sidebar list, header, grouped form content.
- **Variants:** General, Applications, AI, About.
- **States:** native selected, focused, disabled, and validation states.
- **Accessibility:** every setting is a native SwiftUI control with a label;
  keyboard navigation follows AppKit/SwiftUI defaults.

### Background mode picker

- **Structure:** native picker followed by a contextual custom-image row.
- **Variants:** Desktop wallpaper, Current screen, Custom image.
- **States:** selected, live current-screen frosted glass, loading, missing custom file,
  and fallback.
- **Control:** the Blur Amount slider stores a shared `0–100` value, scaled to 50%
  across all modes for a translucent acrylic blur. Static sources dynamically normalize
  Gaussian blur radius by screen point width; Current Screen applies the 50% scaled
  radius to the live material backdrop while keeping the material at full opacity.
- **Motion:** background swaps in place while the existing presentation layer
  remains the source of truth; no layout animation is introduced.

### Launch surface layers

- **Structure:** live current-screen material or blurred image, tint, vignette,
  Metal grid, SwiftUI chrome.
- **States:** prepared, presenting, visible, dismissing, and cached fallback.
- **Motion:** existing fly/classic/zoom/fade/none presentation styles remain the source
  of truth.

## 6. Motion & Interaction

The current animation tokens are intentional: fly 1.3s, classic 0.54s, zoom
0.62s, fade 0.26s, and no-animation 0s. Classic presents the complete launch
grid at once, starting slightly nearer and easing to its resting depth over a
short distance. The complete grid uses the center of the screen as one shared
coordinate origin, preserving the arrangement while all icon positions and sizes
scale together. The depth scale follows the same display-link progress as the
Metal content, and dismissal starts the reverse movement immediately.
Background changes use a short ease-out opacity cross-fade and are cancellable
when a newer selection arrives. Reduced-motion users can select the existing
`none` presentation style.
The blurred background eases in over 0.64s and uses a symmetric fade on dismissal,
while the icon grid keeps its own presentation timing.

## 7. Depth & Surface

The depth strategy is mixed but restrained: semantic AppKit surfaces in Settings,
then image + tint + vignette + glass controls on the launch surface. Avoid
opaque cards over the background; imagery should remain visible as atmosphere,
not compete with the icon grid.

## 8. Accessibility Constraints & Accepted Debt

### Constraints

- Use native controls and labels for settings and file selection.
- Keep text legible over all background modes through the existing tint/vignette.
- Preserve keyboard dismissal, search, and arrow navigation.
- If a screen capture is unavailable because macOS privacy permission is missing,
  fall back to the desktop wallpaper or the semantic visual-effect background.

### Accepted Debt

| Item | Location | Why accepted | Exit |
|---|---|---|---|
| Private WindowServer wallpaper capture | `DesktopBackgroundView.swift` | It gives the closest wallpaper result on macOS while retaining a public fallback | Replace when macOS exposes an equivalent public API |
| Native AppKit visual QA | Settings and launch panel | The project is a native macOS app rather than a browser surface | Exercise on macOS after a build is available |

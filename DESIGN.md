# Scifi UI Design System

> Category: Project Design System
> Surface: desktop web / macOS glassmorphism popups
> Source project: "Scifi Ui Design Menubar Popup Ai" (6e32f780-a480-45e0-ad1a-0ae54d64c0f3)

## Source Context

This system was extracted from two preserved source artifacts in the project workspace:

- `jarvis-voice.html` — 440×440px voice-assistant popup with animated orb, concentric rings, SVG waveform, circular spectrum bars, particle drift, and transcript typing effect.
- `ai-chat-popup.html` — 420×560px chat popup with glass message bubbles (user/assistant), suggestion chips, search input bar, thinking loader, and macOS traffic-light window chrome.

Both files share identical token values, easing curves, border strategies, background treatments, and component anatomy. Every token, measurement, and pattern in this document was derived directly from the CSS in these files. When building with this system, reference the source artifacts for complete implementation details.

## 1. Visual Theme & Atmosphere

**Source context:** Both `jarvis-voice.html` and `ai-chat-popup.html` open with `body { background: #000; }` and a fixed `bg-layer` of layered radial gradients (deep blue orbs at ~15% opacity). This establishes the dark canvas.

A cinematic sci-fi assistant UI built around macOS-style glassmorphism. The mood is dark, precise, and quietly powerful — think JARVIS operating inside a frosted window floating over a void. Deep black backgrounds let ambient cyan-blue light leak through translucent surfaces. Every element feels physical: thin glass edges, glowing accents, and slow orbital motion behind the panes.

**Product context:** AI assistant popups, voice interfaces, and command dashboards that live in a menubar or overlay context. The user is a pilot or operator speaking to a capable system.

**Feeling:** Controlled, futuristic, trustworthy, minimal.

## 2. Color

**Source context:** The `:root` blocks in both `jarvis-voice.html` and `ai-chat-popup.html` declare identical tokens: `--fg: oklch(94% 0.015 260)`, `--muted: oklch(58% 0.05 240)`, and `--accent: oklch(68% 0.15 215)`. All colors are authored in OKLch for perceptual uniformity. The palette is intentionally narrow — one accent, two text levels, and translucent surface tints.

| Token           | Value                    | Role                                                                                               |
| --------------- | ------------------------ | -------------------------------------------------------------------------------------------------- |
| `--bg`          | `#000`                   | Deepest background (pure black) — from `body { background: #000; }` in both sources                |
| `--surface`     | `rgba(255,255,255,0.03)` | Glass panel fill — from `.window { background: rgba(255,255,255,0.03); }`                          |
| `--fg`          | `oklch(94% 0.015 260)`   | Primary text — near-white with cool undertone — verbatim from both `:root` blocks                  |
| `--muted`       | `oklch(58% 0.05 240)`    | Secondary text, placeholders, disabled — verbatim from both `:root` blocks                         |
| `--border`      | `rgba(255,255,255,0.12)` | Glass pane borders, dividers — from `.window { border: 0.5px solid rgba(255,255,255,0.12); }`      |
| `--accent`      | `oklch(68% 0.15 215)`    | Cyan-blue — interactive highlights, focus rings, active states — verbatim from both `:root` blocks |
| `--accent-glow` | `rgba(0,170,255,0.25)`   | Hover glow, orb halos, button borders — observed in hover states across both files                 |
| `--success`     | `#28c840`                | Traffic-light zoom / positive status — from `.tl-zoom { background: #28c840; }`                    |
| `--warning`     | `#febc2e`                | Traffic-light minimize / caution — from `.tl-min { background: #febc2e; }`                         |
| `--danger`      | `#ff5f57`                | Traffic-light close / destructive — from `.tl-close { background: #ff5f57; }`                      |

**Surface hierarchy:**

- **Level 0** — pure black with subtle radial-gradient ambient light (deep blue orbs at ~15% opacity)
- **Level 1** — `.window` glass card at `rgba(255,255,255,0.03)` with `backdrop-filter: blur(80px) saturate(180%) brightness(1.1)`
- **Level 2** — titlebar at `rgba(255,255,255,0.02)` + `0.5px` border-bottom
- **Level 3** — buttons/inputs at `rgba(255,255,255,0.04)` with `blur(10px) saturate(150%)`

## 3. Typography

**Source context:** Both source files declare `--font-body: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif` and `--font-mono: 'SF Mono', ui-monospace, Menlo, monospace` in their `:root` blocks. All type sizes and weights were measured directly from the CSS declarations in `jarvis-voice.html` and `ai-chat-popup.html`.

| Role        | Stack                                                                                    | Size      | Weight  | Tracking   | Notes                                              |
| ----------- | ---------------------------------------------------------------------------------------- | --------- | ------- | ---------- | -------------------------------------------------- |
| **Display** | `-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif` | 36–64px   | 600     | -0.01em    | Hero headlines in slides or landing pages          |
| **Heading** | Same as body                                                                             | 20–28px   | 600     | -0.01em    | Section titles inside glass panels                 |
| **Body**    | `-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif`    | 13–14px   | 400–500 | 0          | Default UI text; anti-aliased                      |
| **Caption** | Same as body                                                                             | 10.5–11px | 450     | 0.04em     | Timestamps, meta lines, hints                      |
| **Mono**    | `'SF Mono', ui-monospace, Menlo, monospace`                                              | 11–13px   | 400     | 0.02em     | Code blocks, assistant replies, status readouts    |
| **Label**   | Same as body                                                                             | 9.5–13px  | 550     | 0.08–0.1em | Uppercase role labels (YOU, JARVIS), status badges |

**Line heights:**

- Body: 1.5
- Mono: 1.5
- Display: 1.1–1.2

## 4. Spacing

**Source context:** Spacing values were measured from padding, margin, gap, height, and radius declarations across both source files. The scale (`4px` → `80px`) covers every increment observed in `jarvis-voice.html` and `ai-chat-popup.html`.

| Token        | Value  | Usage                                                          |
| ------------ | ------ | -------------------------------------------------------------- |
| `--space-1`  | `4px`  | Tight gaps, scrollbar width, icon padding                      |
| `--space-2`  | `8px`  | Chip gaps, traffic-light spacing, icon-btn inset               |
| `--space-3`  | `10px` | Input-area padding, suggestion wrap gap                        |
| `--space-4`  | `12px` | Chip padding-x, icon-btn size (36px)                           |
| `--space-5`  | `14px` | Button/icon radius, body border-radius                         |
| `--space-6`  | `16px` | Window titlebar padding, message padding, card inset           |
| `--space-7`  | `18px` | Message bubble radius                                          |
| `--space-8`  | `20px` | Message area horizontal padding, suggestion horizontal padding |
| `--space-9`  | `32px` | Large shadow offset, titlebar height (40px)                    |
| `--space-10` | `80px` | Blur radii for background orbs                                 |

**Density:** Compact. This is a popup/menubar UI — vertical real estate is scarce. Padding is tight, gutters are narrow, and borders are hairline (`0.5px`).

## 5. Layout & Composition

**Source context:** Window dimensions (`440×440px` for voice, `420×560px` for chat), titlebar height (`40px`), padding (`0 16px`), and `border-radius: 14px` were all measured directly from `.window` and `.titlebar` declarations in the source files.

**Window anatomy:**

- Fixed-size glass cards (e.g. `420×560px` chat, `440×440px` voice) centered on screen.
- `border-radius: 14px` on the window.
- Top-edge 1px highlight gradient (white at 30% opacity, fading to transparent at edges).
- Titlebar: `40px` high, flex row, traffic lights left, centered title, right spacer.
- Content area: flex column, `overflow: hidden` on window, internal scroll on messages.

**Responsive behavior:**

- Primary target is desktop web / macOS menubar popups.
- On narrower viewports, the window scales down proportionally with `max-width: 95vw` and `max-height: 90vh`.
- Touch targets must remain ≥ 44px; icon buttons are 36×36px minimum, with increased padding on tablet.

## 6. Components

**Source context:** All component descriptions below were catalogued from the CSS class definitions in `jarvis-voice.html` and `ai-chat-popup.html`. Every value (backdrop-filter strength, border opacity, shadow stack, animation duration) was copied verbatim from the source.

### Glass Window (`.window`)

- `backdrop-filter: blur(80px) saturate(180%) brightness(1.1)`
- `background: rgba(255,255,255,0.03)`
- `border: 0.5px solid rgba(255,255,255,0.12)`
- `border-radius: 14px`
- Box-shadow stack: inset highlight, inset dark rim, deep drop shadow (`0 32px 100px rgba(0,0,0,0.5)`)
- `::before` pseudo-element for the top-edge 1px light bar.

### Titlebar

- Height `40px`, padding `0 16px`.
- Background `rgba(255,255,255,0.02)`.
- Bottom border `0.5px solid rgba(255,255,255,0.06)`.
- Traffic lights: 12px circles in `#ff5f57`, `#febc2e`, `#28c840`. Icons appear only on hover at 8px stroke.

### Buttons

All buttons share a glass base class (`.btn`):

- `backdrop-filter: blur(10px) saturate(150%)`
- `border: 0.5px solid rgba(255,255,255,0.12)`
- `background: rgba(255,255,255,0.04)`
- `color: var(--muted)`
- Hover: brighter background, accent border tint, subtle glow shadow.
- Active: `scale(0.96)`.

**Variants:**

- `.chip` — pill shape, `border-radius: 999px`, `padding: 6px 14px`, `font-size: 12px`.
- `.icon-btn` — square `36×36px`, `border-radius: 8px`.
- `.btn-primary` — solid accent fill, dark text, hover brightens and glows.

### Input Field

- Height `36px`, `border-radius: 8px`.
- `background: rgba(255,255,255,0.03)` with `border: 0.5px solid rgba(255,255,255,0.08)`.
- Focus: brighter background, accent border, `box-shadow: 0 0 0 3px rgba(0,170,255,0.08)`.
- Search icon absolutely positioned inside left padding.

### Message Bubble

- Max-width `88%`, `border-radius: 18px` with directional corner cut (`6px` on the side closer to the edge).
- User variant: accent-tinted background (`rgba(0,170,255,0.08)`), accent border.
- Assistant variant: neutral glass (`rgba(255,255,255,0.03)`), mono font.
- Entrance animation: `msg-in` — fade + translateY(12px) + scale(0.97) over `0.4s` with signature easing.

### Orb / Voice Button

- Circular `90×90px`, radial-gradient fill with accent tint.
- Glass border + inner glow + outer glow.
- Listening state: brighter fill, stronger shadow, `orb-pulse` scale animation.
- Mic icon `36×36px` with drop-shadow.

### Status Label

- `font-size: 13px`, uppercase, `letter-spacing: 0.08em`, `color: var(--muted)`.
- Listening: switches to accent color with text-shadow glow.

### Thinking Loader

- Three dots `6×6px`, accent fill, staggered `think-bounce` animation (`1.4s ease-in-out`).

### Background Orbs

- Fixed-position circles (`180–300px`), `filter: blur(80px)`, low opacity (`0.15–0.4`).
- Slow drift animation (`18–25s ease-in-out infinite`).

## 7. Motion & Interaction

**Source context:** The signature easing `cubic-bezier(0.2, 0.8, 0.2, 1)` appears in almost every transition across both source files. All keyframes (orb-drift, ring-pulse, orb-pulse, mic-beat, particle-drift, think-bounce, msg-in, blink) were preserved verbatim from the source CSS.

**Signature easing:** `cubic-bezier(0.2, 0.8, 0.2, 1)` — soft deceleration, used for almost every transition.

**Hover states:**

- Buttons: background lightens, border shifts toward accent, glow shadow appears. `transition: all 0.2s` with signature easing.
- Traffic lights: `scale(1.1)` on hover, icon opacity 0 → 1.

**Focus states:**

- Inputs: accent border + soft outer glow ring (`3px` spread at 8% opacity).
- Buttons: same glow pattern.

**Active/press:**

- All interactive elements: `transform: scale(0.96)`.

**Loading / listening:**

- Orb pulse: `scale(1)` ↔ `scale(1.08)` over `2s ease-in-out infinite`.
- Mic beat: `scale(1)` ↔ `scale(0.88)` over `1.2s ease-in-out infinite`.
- Ring pulse: concentric rings scale and fade in staggered waves (`2.5s`).
- Thinking dots: vertical bounce with opacity fade (`1.4s` staggered).
- Particle drift: `4s ease-out infinite`, radiating from center.

**Window chrome animations:**

- Close: opacity `0` + `scale(0.96)` over `0.25s`, then restore after `1.8s`.
- Minimize: `scaleY(0)` from top over `0.2s`, restore after `1.5s`.
- Zoom: width/height resize with `0.3s` transition.

**Reduced motion:**

- Respect `prefers-reduced-motion: reduce` by disabling orb drift, particle drift, ring pulse, and mic beat. Keep instant state changes and simple opacity fades.

## 8. Voice & Brand

**Source context:** Copy tone was inferred from the sample content in `ai-chat-popup.html` (assistant diagnostic replies, user commands, welcome banner) and the status labels in `jarvis-voice.html` ("Tap to speak", "Listening…").

**Copy style:** Direct, concise, slightly formal. The assistant speaks like a capable ops copilot, not a chatty bot.

- Use short imperative sentences for status: _"Listening…"_, _"Processing. One moment, sir."_
- System labels in ALL CAPS with wide tracking: `YOU`, `JARVIS`.
- Timestamps in 24-hour `HH:MM` mono.
- Avoid exclamation marks. Avoid emojis. Avoid filler pleasantries.
- Hints and meta copy are lowercase, small, and unobtrusive: _"Press orb or spacebar"_.

**Terminology:**

- "Orb" for the primary voice button.
- "Traffic lights" for the macOS window controls.
- "Glass" for any translucent frosted surface.

## 9. Anti-patterns

**Source context:** These anti-patterns are the inverse of what the source artifacts actually do. The source uses pure black, one accent, system fonts, hairline borders, and thin-stroke SVGs — never gradients on every background, emojis, or thick colored borders.

- **No warm beige/cream canvases.** Backgrounds stay pure black or very dark cool gray.
- **No purple gradient washes.** Gradients are limited to subtle radial ambient light and the single top-edge glass highlight.
- **No emoji as feature icons.** Use thin-stroke SVGs (2px stroke, `currentColor`).
- **No rounded card with left color-border accent.** Cards are full glass panes with uniform hairline borders.
- **No hand-drawn SVG scenery.** Decorative elements are abstract orbs, rings, and spectrum bars.
- **No Inter/Roboto/Arial as display faces.** Stick to system font stack; body face is fine there.
- **No invented metrics or filler copy.** Missing a real value → honest placeholder label, never a fake stat.
- **No `scrollIntoView` in embedded previews.** It breaks the container; use manual scrollTop instead.
- **No app-chrome color choices.** Palette is driven by the sci-fi brand, not OS defaults.
- **No horizontal scroll on mobile.** Redesign small screens; never squeeze the desktop layout.

# Liova website

The landing page at [krishnarajan7.github.io/Liova](https://krishnarajan7.github.io/Liova/). React 19, TypeScript, Vite,
Tailwind CSS 4, [Motion](https://motion.dev) for springs and scroll effects, [Lenis](https://lenis.dev) for smooth
scrolling, and three bundled fonts (Bricolage Grotesque, Figtree, Caveat). It ships as static files, makes no requests to anyone else, and sets no cookies.

```bash
cd site
pnpm install
pnpm dev        # http://localhost:5173, reloads as you edit
pnpm build      # type-checks, then writes dist/
pnpm preview    # serves dist/ at http://localhost:4173
```

Needs Node 20.19 or later and pnpm 10.

## How it's put together

| Path | What |
| --- | --- |
| `src/App.tsx` | The page: sections in order |
| `src/components/MenuBar.tsx` | The page wears a macOS menu bar with a live notch in the middle; on phones, a Dynamic Island |
| `src/components/notch/director.tsx` | Lets each section drive that notch while it's in the middle of the screen (`useNotchScene`) |
| `src/components/notch/Notch.tsx` | `NotchShell` (the black shape that springs between sizes), `SceneContent` and `shapeFor` |
| `src/components/Closeup.tsx` | The top of a Mac's screen, magnified, showing one notch state |
| `src/components/Wallpaper.tsx` | The blue-hour dunes wallpaper, drawn in SVG |
| `src/components/ui.tsx` | `Reveal` (rise into view), `Marker` (pen underline), `Circled` (hand-drawn ring), `Note` (pen arrow and words), `Button`, `SectionHeader` |
| `src/sections/` | `Hero`, `Story` (pinned, scroll-driven chapters), `More`, `Numbers`, `Agents`, `Scriptable`, `Privacy`, `Faq`, `Final` with the footer |
| `src/Still.tsx` | Single close-ups for images, at `?still=music`, `player`, `agent`, `charging`, `download`, `airpods` and `og` |

**The idea.** The notch at the top of the page is the demo. While a section is in the middle of the screen it tells
that notch what to show: the story's chapters, the agent demo's state, a script's progress, the camera dots while you
read about privacy. Up top it stays compact (hover or tap to open); the close-ups show the full cards.

**Look.** Liova's own: cool paper, true black (the notch's colour) and ballpoint-pen blue for everything written by
hand. Bricolage Grotesque for headlines, Figtree for text and Caveat for the pen notes, which echo the script "Li" in
the app icon; all three are OFL and bundled. Pen notes (`Note` in `ui.tsx`) draw their arrow, then write their words,
wherever the page wants to nudge you: the live notch, the story, the 0.0%, the agent's buttons, Run, the download
button and the footer, whose "liova" has a live notch for the dot on its i.

**Motion.** Springs that never overshoot, like the app. Text rises 26 px into place once, staggered. The story pins
and swaps chapters with the scroll, in both directions. Anything that loops stops off screen, and **Reduce motion**
turns motion and smooth scrolling off.

**Honesty.** The notch is a faithful rebuild of Liova's UI in HTML, not a video. Numbers come from
[PERFORMANCE.md](../docs/PERFORMANCE.md); update both together.

## Images for the README

```bash
pnpm build && pnpm preview &
scripts/capture-stills.sh          # → ../docs/images/notch-*.jpg and public/og.png
```

The script screenshots each `?still=` page with headless Chrome at 2x.

## Publishing

`.github/workflows/site.yml` builds every change to `site/` and publishes `main` to GitHub Pages under `/Liova/`
(`SITE_BASE`). Pages has to be switched on once: **Settings → Pages → Source: GitHub Actions**. With a custom domain,
build with `SITE_BASE=/` and update `og:url` and `og:image` in `index.html`.

The GitHub star count beside "Star on GitHub" is read from GitHub's API when the site is built (`vite.config.ts`),
so visitors' browsers never contact GitHub. The workflow also runs daily to keep it current. If the API can't be
reached, the count is simply left out.

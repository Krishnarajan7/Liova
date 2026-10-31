import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "motion/react";
import { useRef, useState } from "react";
import { Closeup } from "../components/Closeup";
import { type Scene, useNotchScene } from "../components/notch/director";
import { Note, Words } from "../components/ui";

const chapters: { scene: Scene; label: string; title: string; body: string }[] = [
  {
    scene: "lyrics",
    label: "Now Playing",
    title: "Music, with the words.",
    body: "Spotify, Apple Music, YouTube in your browser. A line ripples in the album's colour while it plays, and the line being sung slides in under the notch.",
  },
  {
    scene: "player",
    label: "Hover to open",
    title: "Everything, one hover away.",
    body: "Artwork, a scrubber you can drag, repeat, and a two-finger swipe to skip. Move away and it tucks itself back in.",
  },
  {
    scene: "agent-asking",
    label: "Agent Island",
    title: "Your agent asks. You answer.",
    body: "Claude Code and Codex ask before they run a command. Allow or deny right from the notch, without leaving what you're doing.",
  },
  {
    scene: "charging",
    label: "Charging",
    title: "Plug in, and it shows.",
    body: "A battery fills, a bolt pops in, and a streak of light runs along the notch. Then it gets out of the way.",
  },
  {
    scene: "airpods",
    label: "AirPods and headphones",
    title: "Every bud, at a glance.",
    body: "Battery for each bud and the case the moment they connect, and a nudge before they run out.",
  },
  {
    scene: "download",
    label: "Downloads",
    title: "Downloads, live.",
    body: "Size, speed and time left for browser and Telegram downloads. Liova reads names and sizes, never what's inside.",
  },
];

/**
 * Pinned while you scroll through it: each stretch of scrolling is one chapter. The close-up
 * and the real notch at the top of the page both follow, and scrolling back plays it in reverse.
 */
export function Story() {
  const section = useRef<HTMLElement>(null);
  const [index, setIndex] = useState(0);
  const { scrollYProgress } = useScroll({ target: section, offset: ["start start", "end end"] });
  useMotionValueEvent(scrollYProgress, "change", (p) => {
    setIndex(Math.min(chapters.length - 1, Math.max(0, Math.floor(p * chapters.length))));
  });
  const chapter = chapters[index]!;
  useNotchScene("story", section, chapter.scene);

  return (
    <section id="story" ref={section} className="relative" style={{ height: `${chapters.length * 85 + 40}vh` }}>
      <div className="sticky top-0 mx-auto flex h-[100svh] max-w-[1180px] flex-col items-center justify-center gap-[clamp(24px,5vh,48px)] overflow-hidden px-5 pt-14 md:flex-row md:gap-[clamp(32px,5vw,72px)] md:px-10">
        {/* Words */}
        <div className="order-2 w-full max-w-[30rem] md:order-1 md:w-[34%] md:max-w-none md:flex-none">
          <div className="flex gap-1.5" aria-hidden="true">
            {chapters.map((c, i) => (
              <motion.span
                key={c.scene}
                className="h-[3px] rounded-full bg-ink"
                animate={{ width: i === index ? 28 : 10, opacity: i === index ? 1 : 0.18 }}
                transition={{ type: "spring", bounce: 0, duration: 0.5 }}
              />
            ))}
          </div>
          <div className="relative mt-6 min-h-[13.5rem] md:min-h-[16rem]">
            <AnimatePresence mode="wait" initial={false}>
              <motion.div
                key={chapter.scene}
                initial={{ opacity: 0, y: 26 }}
                animate={{ opacity: 1, y: 0, transition: { duration: 0.6, ease: [0.22, 1, 0.36, 1] } }}
                exit={{ opacity: 0, y: -18, transition: { duration: 0.25 } }}
              >
                <p className="label">{chapter.label}</p>
                <h2 className="display mt-3 text-[clamp(2.1rem,4.6vw,3.9rem)]">
                  <Words now>{chapter.title}</Words>
                </h2>
                <p className="mt-4 max-w-md text-[clamp(1rem,1.4vw,1.15rem)] leading-relaxed text-ink-soft">{chapter.body}</p>
              </motion.div>
            </AnimatePresence>
          </div>
        </div>
        {/* The close-up */}
        <div className="relative order-1 w-full max-w-[640px] md:order-2 md:flex-1">
          <Note arrow="up" text="the real one up top is doing it too" className="-top-[86px] right-[8%] hidden md:flex" delay={0.4} />
          <Closeup scene={chapter.scene} />
          <p className="label mt-4 text-center text-ink-faint md:hidden">Look up: the island on this page is doing it too.</p>
        </div>
      </div>
    </section>
  );
}

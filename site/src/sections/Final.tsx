import { AnimatePresence, motion, useInView } from "motion/react";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { Bolt, Github, Sparkle } from "../components/Icons";
import { MusicWave } from "../components/notch/parts";
import { Button, Marker, Note, Reveal, stars, Words } from "../components/ui";
import { StarCount } from "./Hero";
import { CHANGELOG, DISCUSSIONS, DOCS, GET_IT, ISSUES, REPO, spring, external } from "../site";

export function Final() {
  return (
    <section className="px-5 pb-10 pt-[clamp(110px,16vh,180px)] text-center">
      <Reveal>
        <img src="icon.png" alt="" width={88} height={88} className="mx-auto size-[88px] rounded-[22px] shadow-[0_18px_40px_-16px_rgba(0,0,0,.35)]" />
      </Reveal>
      <Reveal delay={0.08}>
        <h2 className="display mx-auto mt-8 max-w-3xl text-[clamp(2.4rem,6vw,4.6rem)]">
          <Words>
            Give your notch <Marker delay={0.7}>something to do.</Marker>
          </Words>
        </h2>
      </Reveal>
      <Reveal delay={0.16}>
        <p className="mx-auto mt-5 max-w-md text-[18px] leading-relaxed text-ink-soft">
          Free, open source and made for the Mac. Two minutes from now, it's yours.
        </p>
      </Reveal>
      <Reveal delay={0.24} className="relative mx-auto mt-9 flex w-fit flex-wrap justify-center gap-3">
        <Note arrow="left" text="two minutes, promise" className="-right-[230px] top-1 hidden lg:flex" delay={0.6} />
        <Button href={GET_IT} arrow>
          Get Liova for Mac
        </Button>
        <Button href={REPO} variant="soft" icon={<Github size={17} />}>
          Star on GitHub
          {stars !== null && <StarCount count={stars} />}
        </Button>
      </Reveal>
      <Reveal delay={0.3}>
        <p className="label mt-5 text-ink-faint">macOS 14 or later · Apple Silicon and Intel</p>
      </Reveal>
    </section>
  );
}

const links = [
  { label: "GitHub", href: REPO },
  { label: "Documentation", href: DOCS },
  { label: "Changelog", href: CHANGELOG },
  { label: "Discussions", href: DISCUSSIONS },
  { label: "Report a bug", href: ISSUES },
];

/** What the i's notch shows, one after another, while the footer is on screen. */
const moments: { width: number; content: ReactNode }[] = [
  { width: 1, content: null },
  { width: 2.6, content: <MusicWave width={20} height={10} /> },
  { width: 1, content: null },
  { width: 2.3, content: <Bolt size={13} className="text-leaf" /> },
  { width: 1, content: null },
  { width: 2.3, content: <Sparkle size={13} className="text-ember" /> },
];

/**
 * The name, huge, with a notch for the dot on its i, like the bar over the i in the app icon.
 * The notch wakes up now and then, the way Liova does: briefly, then back to rest.
 */
function Wordmark() {
  const ref = useRef<HTMLDivElement>(null);
  const live = useInView(ref);
  const [step, setStep] = useState(0);
  const [hovered, setHovered] = useState(false);
  useEffect(() => {
    if (!live || hovered) return;
    const id = window.setTimeout(() => setStep((s) => (s + 1) % moments.length), step % 2 === 0 ? 1800 : 2400);
    return () => window.clearTimeout(id);
  }, [live, hovered, step]);
  const moment = hovered ? { width: 2.8, content: <MusicWave width={20} height={10} /> } : moments[step]!;

  return (
    <div ref={ref} className="relative mx-auto w-fit select-none" aria-label="Liova">
      <p
        aria-hidden="true"
        className="display text-[clamp(7.5rem,31vw,27rem)] leading-[0.78] tracking-[-0.02em] text-ink"
        style={{ fontStretch: "88%" }}
      >
        l
        {/* No letter spacing on the i itself, so its box is centred on the glyph and so is the dot. */}
        <span className="relative mx-[-0.01em] inline-block tracking-normal">
          {"\u0131"}
          {/* The dot: a notch, centred over the dotless i while it rests. It opens to the right,
              over the o, because the l leaves no room on the left. */}
          <span
            className="absolute left-[calc(50%-0.06em)] top-[0.035em] flex"
            onPointerEnter={() => setHovered(true)}
            onPointerLeave={() => setHovered(false)}
          >
            <motion.span
              className="flex h-[0.12em] items-center justify-center overflow-hidden rounded-[0.06em] bg-notch"
              animate={{ width: `${moment.width * 0.12}em` }}
              transition={spring}
            >
              <AnimatePresence mode="popLayout" initial={false}>
                {moment.content && (
                  <motion.span
                    key={step + (hovered ? "h" : "")}
                    initial={{ opacity: 0, scale: 0.6 }}
                    animate={{ opacity: 1, scale: 1, transition: { delay: 0.15 } }}
                    exit={{ opacity: 0, scale: 0.6 }}
                    className="flex text-[16px] leading-none"
                  >
                    {moment.content}
                  </motion.span>
                )}
              </AnimatePresence>
            </motion.span>
          </span>
        </span>
        ova
      </p>
      <Note arrow="left" text="the dot is a notch, obviously" className="left-[37%] top-[1%] hidden md:flex" delay={0.6} size={24} rotate={-4} />
    </div>
  );
}

export function Footer() {
  return (
    <footer className="relative overflow-hidden px-5 pt-6">
      <Reveal className="mx-auto mb-10 flex max-w-5xl flex-col items-center gap-6 border-t border-line pt-10 md:flex-row md:justify-between">
        <p className="text-center text-[15px] font-medium text-ink-soft md:text-left">
          The notch, finally useful. <span className="text-ink-faint">Made in the open, for the Mac.</span>
        </p>
        <nav aria-label="Footer" className="flex flex-wrap justify-center gap-x-6 gap-y-2">
          {links.map((link) => (
            <a key={link.label} href={link.href} {...external} className="text-[14px] font-semibold text-ink-soft hover:text-ink">
              {link.label}
            </a>
          ))}
        </nav>
      </Reveal>
      <Wordmark />
      <p className="mx-auto mb-8 mt-10 max-w-2xl text-center text-[12.5px] leading-relaxed text-ink-faint">
        © {new Date().getFullYear()} Krishnarajan · MIT license. Mac, AirPods and Dynamic Island are trademarks of Apple
        Inc., used only to describe what Liova works with; Liova is not affiliated with or endorsed by Apple. This site sets
        no cookies and loads nothing from anyone else.
      </p>
    </footer>
  );
}

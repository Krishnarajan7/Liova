import { motion } from "motion/react";
import { Github, Star } from "../components/Icons";
import { Button, formatStars, Marker, Note, stars, Words } from "../components/ui";
import { GET_IT, REPO } from "../site";

const rise = (delay: number) => ({
  initial: { opacity: 0, y: 26 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.9, delay, ease: [0.22, 1, 0.36, 1] as const },
});

/** The star count beside "Star on GitHub". */
export function StarCount({ count }: { count: number }) {
  return (
    <span className="numeric -mr-2 ml-1 flex items-center gap-1 rounded-full bg-ink/[0.07] px-2.5 py-0.5 text-[13px]" aria-label={`${count} stars`}>
      <Star size={12} />
      {formatStars(count)}
    </span>
  );
}

export function Hero() {
  return (
    <section id="top" className="relative isolate flex min-h-[100svh] flex-col items-center justify-center px-5 pb-24 pt-32 text-center">
      {/* Ruled paper at the edges, the page the pen notes are written on; it fades out behind the words. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 -z-10"
        style={{
          backgroundImage:
            "linear-gradient(to bottom, transparent 31px, color-mix(in oklab, var(--color-pen) 16%, transparent) 31px, color-mix(in oklab, var(--color-pen) 16%, transparent) 32px)",
          backgroundSize: "100% 32px",
          maskImage:
            "radial-gradient(ellipse 34% 60% at 50% 52%, transparent 55%, black 100%), linear-gradient(to bottom, transparent, black 18%, black 75%, transparent)",
          maskComposite: "intersect",
          WebkitMaskComposite: "source-in",
        }}
      />
      {/* The notebook's margin line. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-y-0 left-[clamp(28px,7vw,120px)] -z-10 hidden w-px md:block"
        style={{
          background: "color-mix(in oklab, var(--color-rose) 35%, transparent)",
          maskImage: "linear-gradient(to bottom, transparent, black 18%, black 75%, transparent)",
        }}
      />
      <Note
        arrow="up"
        text="Psst, it's live. Hover it."
        className="left-1/2 top-[clamp(46px,6.5vh,64px)] -ml-[16px] hidden md:flex"
        delay={1.1}
        size={24}
      />
      <Note
        arrow="up"
        text="Psst, tap it."
        className="left-1/2 top-[54px] -ml-[16px] md:hidden"
        delay={1.1}
        size={20}
      />
      <h1 className="display mx-auto max-w-5xl text-[clamp(2.9rem,8vw,6.6rem)]">
        <Words now delay={0.2}>
          Your notch,
          <br />
          finally <Marker delay={1.05}>useful.</Marker>
        </Words>
      </h1>
      <motion.p
        {...rise(0.7)}
        className="mx-auto mt-6 max-w-[34rem] text-[clamp(1.1rem,1.8vw,1.3rem)] leading-relaxed text-ink-soft"
      >
        Music and lyrics, charging, AirPods, downloads and your coding agents, right where the camera is. Free, open
        source, and asleep when there's nothing to show.
      </motion.p>
      <motion.div {...rise(0.85)} className="mt-9 flex flex-wrap items-center justify-center gap-3">
        <Button href={GET_IT} arrow>
          Get Liova for Mac
        </Button>
        <Button href={REPO} variant="soft" icon={<Github size={17} />}>
          Star on GitHub
          {stars !== null && <StarCount count={stars} />}
        </Button>
      </motion.div>
      <motion.p {...rise(0.95)} className="label mt-5 text-ink-faint">
        macOS 14 or later · Apple Silicon and Intel · Free forever
      </motion.p>
    </section>
  );
}


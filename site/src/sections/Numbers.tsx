import { animate, motion, useInView, useMotionValue, useTransform } from "motion/react";
import { useEffect, useRef } from "react";
import { Circled, Note, Reveal, SectionHeader } from "../components/ui";
import { PERFORMANCE, external } from "../site";

/** Measured on a MacBook Air M4 with `make perf` (docs/PERFORMANCE.md). */
const stats = [
  { to: 0.0, from: 4.8, decimals: 1, suffix: "%", label: "CPU while idle", note: "Measured: 0.002%", circled: true },
  { to: 30, from: 0, decimals: 0, suffix: " MB", label: "Memory, helpers included", note: "Less than a browser tab" },
  { to: 0.2, from: 0, decimals: 1, suffix: " s", label: "Launch to notch", note: "160 to 190 ms" },
  { to: 0, from: 9, decimals: 0, suffix: "", label: "Trackers", note: "No analytics, ever" },
];

function Count({ to, from, decimals, suffix }: { to: number; from: number; decimals: number; suffix: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useInView(ref, { once: true, margin: "0px 0px -20% 0px" });
  const value = useMotionValue(from);
  const text = useTransform(value, (v) => `${v.toFixed(decimals)}${suffix}`);
  useEffect(() => {
    if (!seen) return;
    const controls = animate(value, to, { duration: 1.6, ease: [0.16, 1, 0.3, 1] });
    return () => controls.stop();
  }, [seen, value, to]);
  return <motion.span ref={ref}>{text}</motion.span>;
}

export function Numbers() {
  return (
    <section className="bg-paper-deep/60 px-5 py-[clamp(96px,14vh,160px)]">
      <SectionHeader
        label="Quiet by design"
        title="On screen all day. Felt by no one."
        body="A notch app never quits, so it has to cost nothing. Music, battery, displays and agents tell Liova when something changes, and in between it sleeps. The one thing on a timer, the check for apps heating your Mac, runs once a minute."
      />
      <div className="relative mx-auto mt-16 grid max-w-5xl grid-cols-2 gap-x-6 gap-y-12 lg:grid-cols-4">
        <Note arrow="down" arrowFirst={false} text="yes, really. we measured." className="-top-14 left-[-4%] hidden lg:flex" delay={1.8} rotate={-6} />
        {stats.map((stat, index) => (
          <Reveal key={stat.label} delay={index * 0.08} className="text-center">
            <p className="numeric text-[clamp(2.8rem,6vw,4.4rem)] font-bold leading-none tracking-[-0.03em]">
              {stat.circled ? (
                <Circled delay={1.4}>
                  <Count to={stat.to} from={stat.from} decimals={stat.decimals} suffix={stat.suffix} />
                </Circled>
              ) : (
                <Count to={stat.to} from={stat.from} decimals={stat.decimals} suffix={stat.suffix} />
              )}
            </p>
            <p className="mt-4 text-[16px] font-semibold">{stat.label}</p>
            <p className="mt-0.5 text-[14px] text-ink-soft">{stat.note}</p>
          </Reveal>
        ))}
      </div>
      <Reveal delay={0.2} className="mt-12 text-center">
        <a href={PERFORMANCE} {...external} className="text-[15px] font-semibold underline decoration-ink/25 underline-offset-4 hover:decoration-ink">
          How we measure, and every rule we follow
        </a>
      </Reveal>
    </section>
  );
}

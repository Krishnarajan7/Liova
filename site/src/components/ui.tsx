import { motion, useInView } from "motion/react";
import { Children, type ComponentProps, Fragment, isValidElement, type ReactNode, useRef } from "react";
import { external } from "../site";
import { Arrow } from "./Icons";

const ease = [0.22, 1, 0.36, 1] as const;

/** Rises 26 px into place the first time it scrolls into view. */
export function Reveal({ children, delay = 0, className }: { children: ReactNode; delay?: number; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const seen = useInView(ref, { once: true, margin: "0px 0px -15% 0px" });
  return (
    <motion.div
      ref={ref}
      className={className}
      initial={{ opacity: 0, y: 26 }}
      animate={seen ? { opacity: 1, y: 0 } : undefined}
      transition={{ duration: 0.9, delay, ease }}
    >
      {children}
    </motion.div>
  );
}

const word = {
  hidden: { opacity: 0, y: "0.4em", filter: "blur(10px)" },
  shown: { opacity: 1, y: 0, filter: "blur(0px)", transition: { duration: 0.8, ease } },
};

/**
 * A headline that arrives word by word. `now` plays it on load (the hero); otherwise it plays
 * the first time it scrolls into view. Strings are split into words; anything else (a Marker,
 * say) arrives as one piece, and a <br /> stays a line break.
 */
export function Words({ children, delay = 0, now = false }: { children: ReactNode; delay?: number; now?: boolean }) {
  const pieces: ReactNode[] = [];
  const flat = (node: ReactNode): ReactNode[] =>
    Children.toArray(node).flatMap((child) =>
      isValidElement<{ children?: ReactNode }>(child) && child.type === Fragment ? flat(child.props.children) : [child],
    );
  flat(children).forEach((child, i) => {
    if (typeof child === "string") {
      for (const [j, part] of child.split(/(\s+)/).entries()) {
        if (!part) continue;
        pieces.push(
          /^\s+$/.test(part) ? (
            " "
          ) : (
            <motion.span key={`${i}-${j}`} variants={word} className="inline-block">
              {part}
            </motion.span>
          ),
        );
      }
    } else if (isValidElement(child) && child.type === "br") {
      pieces.push(<br key={i} />);
    } else if (child != null && child !== false) {
      pieces.push(
        <motion.span key={i} variants={word} className="inline-block">
          {child}
        </motion.span>,
      );
    }
  });
  return (
    <motion.span
      initial="hidden"
      animate={now ? "shown" : undefined}
      whileInView={now ? undefined : "shown"}
      viewport={{ once: true, margin: "0px 0px -10% 0px" }}
      transition={{ staggerChildren: 0.07, delayChildren: delay }}
    >
      {pieces}
    </motion.span>
  );
}

/** The repository's star count, read from GitHub when the site was built. */
export const stars: number | null = __GITHUB_STARS__;

export function formatStars(count: number) {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10_000 ? 0 : 1).replace(/\.0$/, "")}k` : String(count);
}

/** A pen underline swept under a word, left to right, once it's in view. */
export function Marker({ children, color = "var(--color-pen)", delay = 0.35 }: { children: ReactNode; color?: string; delay?: number }) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useInView(ref, { once: true, margin: "0px 0px -10% 0px" });
  return (
    <span ref={ref} className="relative inline-block whitespace-nowrap">
      {children}
      <svg
        aria-hidden="true"
        className="pointer-events-none absolute -bottom-[0.16em] left-[-2%] h-[0.32em] w-[104%] overflow-visible"
        viewBox="0 0 300 20"
        preserveAspectRatio="none"
      >
        <motion.path
          d="M4 14 C 60 6, 120 4, 180 8 S 270 14, 296 6"
          fill="none"
          stroke={color}
          strokeWidth="5"
          strokeLinecap="round"
          initial={{ pathLength: 0 }}
          animate={seen ? { pathLength: 1 } : undefined}
          transition={{ duration: 0.75, delay, ease: [0.65, 0, 0.35, 1] }}
        />
      </svg>
    </span>
  );
}

/** A loose hand-drawn ring around a word, drawn in one stroke. */
export function Circled({ children, color = "var(--color-pen)", delay = 0.5 }: { children: ReactNode; color?: string; delay?: number }) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useInView(ref, { once: true, margin: "0px 0px -10% 0px" });
  return (
    <span ref={ref} className="relative inline-block whitespace-nowrap">
      {children}
      <svg
        aria-hidden="true"
        className="pointer-events-none absolute left-[-14%] top-[-30%] h-[160%] w-[128%] overflow-visible"
        viewBox="0 0 200 80"
        preserveAspectRatio="none"
      >
        <motion.path
          d="M18 44 C 14 18, 70 6, 112 8 C 160 10, 192 22, 190 42 C 188 64, 140 76, 96 74 C 50 72, 12 62, 14 40 C 15 28, 40 16, 70 12"
          fill="none"
          stroke={color}
          strokeWidth="3"
          strokeLinecap="round"
          initial={{ pathLength: 0 }}
          animate={seen ? { pathLength: 1 } : undefined}
          transition={{ duration: 0.9, delay, ease: [0.65, 0, 0.35, 1] }}
        />
      </svg>
    </span>
  );
}

type ButtonProps = ComponentProps<"a"> & { variant?: "ink" | "soft"; icon?: ReactNode; arrow?: boolean };

export function Button({ variant = "ink", icon, arrow, children, className = "", ...props }: ButtonProps) {
  const offsite = props.href?.startsWith("http") ? external : {};
  const styles = {
    ink: "bg-ink text-paper shadow-[inset_0_1px_0_rgba(255,255,255,.14),0_10px_24px_-10px_rgba(0,0,0,.6)] hover:bg-black",
    soft: "bg-ink/[0.06] text-ink hover:bg-ink/[0.1]",
  }[variant];
  return (
    <a
      {...offsite}
      className={`group inline-flex items-center gap-2 rounded-full px-6 py-3 text-[15px] font-semibold transition-[background,transform] duration-200 active:scale-[0.97] ${styles} ${className}`}
      {...props}
    >
      {icon}
      {children}
      {arrow && <Arrow size={15} className="transition-transform duration-300 group-hover:translate-x-0.5" />}
    </a>
  );
}

export function SectionHeader({
  label,
  title,
  body,
  align = "center",
}: {
  label: string;
  title: ReactNode;
  body?: ReactNode;
  align?: "center" | "left";
}) {
  return (
    <header className={`${align === "center" ? "mx-auto text-center" : ""} max-w-3xl`}>
      <Reveal>
        <p className="label">{label}</p>
      </Reveal>
      <h2 className="display mt-3 text-[clamp(2.2rem,5.2vw,4rem)]">
        <Words delay={0.08}>{title}</Words>
      </h2>
      {body && (
        <Reveal delay={0.16}>
          <p className={`mt-5 max-w-2xl text-[clamp(1.05rem,1.5vw,1.2rem)] leading-relaxed text-ink-soft ${align === "center" ? "mx-auto" : ""}`}>
            {body}
          </p>
        </Reveal>
      )}
    </header>
  );
}

/** Hand-drawn arrows, each pointing from its note towards something. */
const arrows = {
  // From the note at the bottom right, curving up to a target above-left.
  up: { box: [64, 74], body: "M54 70 C 30 66, 12 50, 16 8", head: "M7 18 L16 6 L25 17" },
  // From the note at the top left, swooping down to a target below-right.
  down: { box: [90, 80], body: "M6 6 C 40 4, 76 22, 78 66", head: "M68 58 L78 70 L86 57" },
  // From the note on the right, curving left to a target on the left.
  left: { box: [96, 56], body: "M92 34 C 72 4, 38 16, 10 26", head: "M18 16 L10 26 L23 29" },
  // From the note on the left, curving right to a target on the right.
  right: { box: [96, 56], body: "M4 34 C 24 4, 58 16, 86 26", head: "M78 16 L86 26 L73 29" },
  // A playful loop before heading down to the target.
  loop: { box: [100, 96], body: "M8 10 C 50 0, 70 30, 50 42 C 30 54, 26 26, 52 30 C 78 34, 84 62, 80 88", head: "M70 80 L80 92 L89 79" },
} as const;

/**
 * A note written on the page in pen: the arrow draws itself, then the words appear as if
 * written left to right. Position it with `className` (it's absolutely placed by its parent).
 */
export function Note({
  text,
  arrow,
  className = "",
  delay = 0.2,
  arrowFirst = true,
  size = 21,
  rotate = -3,
}: {
  text: string;
  arrow: keyof typeof arrows;
  className?: string;
  delay?: number;
  /** Arrow before the words (left/above) or after them. */
  arrowFirst?: boolean;
  size?: number;
  rotate?: number;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const seen = useInView(ref, { once: true, margin: "0px 0px -12% 0px" });
  const shape = arrows[arrow];
  const drawn = (d: string, at: number, duration: number) => (
    <motion.path
      d={d}
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      initial={{ pathLength: 0, opacity: 0 }}
      animate={seen ? { pathLength: 1, opacity: 1 } : undefined}
      transition={{ pathLength: { delay: at, duration, ease: [0.65, 0, 0.35, 1] }, opacity: { delay: at, duration: 0.01 } }}
    />
  );
  const svg = (
    <svg width={shape.box[0]} height={shape.box[1]} viewBox={`0 0 ${shape.box[0]} ${shape.box[1]}`} fill="none" aria-hidden="true" className="shrink-0 text-pen">
      {drawn(shape.body, delay, 0.75)}
      {drawn(shape.head, delay + 0.7, 0.25)}
    </svg>
  );
  const words = (
    <motion.p
      className="hand whitespace-nowrap"
      style={{ fontSize: size, rotate }}
      initial={{ clipPath: "inset(0 100% 0 0)" }}
      animate={seen ? { clipPath: "inset(0 0% 0 0)" } : undefined}
      transition={{ delay: delay + 0.85, duration: 0.7, ease: "easeOut" }}
    >
      {text}
    </motion.p>
  );
  return (
    <div ref={ref} aria-hidden="true" className={`pointer-events-none absolute flex items-start gap-1.5 ${className}`}>
      {arrowFirst ? svg : words}
      {arrowFirst ? words : svg}
    </div>
  );
}

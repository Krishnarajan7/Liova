import { motion, useMotionValueEvent, useScroll } from "motion/react";
import { useEffect, useState } from "react";
import { GET_IT, REPO, external } from "../site";
import { Battery, Github, Star, Wifi } from "./Icons";
import { formatStars, stars } from "./ui";
import { type Scene, useDirector } from "./notch/director";
import { type NotchVariant, NotchShell, SceneContent, shapeFor } from "./notch/Notch";

/** What the notch does on its own between sections: compact moments only, never big cards. */
const demo: { scene: Scene; ms: number }[] = [
  { scene: "lyrics", ms: 6600 },
  { scene: "charging", ms: 3200 },
  { scene: "airpods", ms: 3000 },
  { scene: "volume", ms: 2600 },
];

function useMedia(query: string) {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const list = window.matchMedia(query);
    const update = () => setMatches(list.matches);
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, [query]);
  return matches;
}

function useViewportWidth() {
  const [width, setWidth] = useState(() => window.innerWidth);
  useEffect(() => {
    const update = () => setWidth(window.innerWidth);
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);
  return width;
}

/** The live notch at the top of the page, reacting to whatever section is on screen. */
function LiveNotch({ variant }: { variant: NotchVariant }) {
  const { scene: directed, detail } = useDirector();
  const width = useViewportWidth();
  const [step, setStep] = useState(0);
  const [hovered, setHovered] = useState(false);
  const cycling = directed === "demo";

  useEffect(() => {
    if (!cycling || hovered) return;
    const id = window.setTimeout(() => setStep((s) => (s + 1) % demo.length), demo[step]!.ms);
    return () => window.clearTimeout(id);
  }, [cycling, hovered, step]);

  // A real MacBook's camera housing is about an eighth of the screen's width.
  const camera = variant === "island" ? 118 : Math.round(Math.min(210, Math.max(150, width * 0.125)));
  let scene: Scene = cycling ? demo[step]!.scene : directed;
  let shown = detail;
  if (cycling && hovered) scene = scene === "download" ? "download" : "player";
  // Sections show the big card in their own close-up; up here the notch stays compact unless
  // you hover (or tap) it, so it never covers what you're reading.
  if (!hovered) {
    if (scene === "player") scene = "lyrics";
    if (scene === "agent-asking") [scene, shown] = ["agent-working", { status: "Wants to run git push" }];
    if (scene === "download") [scene, shown] = ["run", { progress: 0.82, title: "Liova.dmg" }];
  }
  const shape = shapeFor(scene, variant, camera);

  return (
    <div
      className="pointer-events-auto"
      onPointerEnter={(e) => e.pointerType === "mouse" && setHovered(true)}
      onPointerLeave={(e) => e.pointerType === "mouse" && setHovered(false)}
      onClick={() => setHovered((h) => !h)}
    >
      <NotchShell shape={shape} variant={variant} contentKey={`${scene}-${variant}`}>
        <SceneContent scene={scene} variant={variant} detail={shown} />
      </NotchShell>
    </div>
  );
}

const links = [
  { href: "#story", label: "Features" },
  { href: "#agents", label: "Agents" },
  { href: "#privacy", label: "Privacy" },
  { href: "#faq", label: "FAQ" },
];

/**
 * Desktop: the page wears a macOS menu bar, with the notch in its middle.
 * Phones: a Dynamic Island floats at the top instead.
 */
export function MenuBar() {
  const wide = useMedia("(min-width: 768px)");
  const { scrollY } = useScroll();
  const [scrolled, setScrolled] = useState(false);
  useMotionValueEvent(scrollY, "change", (y) => setScrolled(y > 8));
  const [clock, setClock] = useState(() => new Date());
  useEffect(() => {
    const id = window.setInterval(() => setClock(new Date()), 20_000);
    return () => window.clearInterval(id);
  }, []);

  if (!wide) {
    return (
      <header className="pointer-events-none fixed inset-x-0 top-0 z-50">
        <div
          className={`absolute inset-x-0 top-0 h-[58px] transition-[background,backdrop-filter] duration-300 ${
            scrolled ? "bg-paper/80 backdrop-blur-xl" : ""
          }`}
        />
        <div className="relative flex h-[58px] items-center justify-between px-4">
          <a href="#top" className="pointer-events-auto" aria-label="Liova home">
            <img src="icon.png" alt="" width={38} height={38} className="size-[38px] rounded-[10px] shadow-[0_2px_6px_rgba(0,0,0,.18)]" />
          </a>
          <a
            href={GET_IT} {...external}
            className="pointer-events-auto rounded-full bg-ink px-3.5 py-1.5 text-[13px] font-semibold text-paper"
          >
            Get
          </a>
        </div>
        <div className="absolute inset-x-0 top-[11px] flex justify-center">
          <LiveNotch variant="island" />
        </div>
      </header>
    );
  }

  return (
    <motion.header
      className="fixed inset-x-0 top-0 z-50"
      initial={{ y: -32 }}
      animate={{ y: 0 }}
      transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
    >
      <nav
        aria-label="Main"
        className={`relative flex h-8 items-center justify-between px-4 text-[13px] transition-[background,box-shadow] duration-300 ${
          scrolled ? "bg-paper/80 shadow-[0_1px_0_rgba(0,0,0,.08)] backdrop-blur-xl" : "bg-paper/40 backdrop-blur-md"
        }`}
      >
        <div className="flex items-center gap-1">
          <a href="#top" className="flex items-center gap-2 rounded-md px-1.5 py-0.5 text-[14px] font-bold hover:bg-ink/[0.06]">
            <img src="icon.png" alt="" width={22} height={22} className="size-[22px] rounded-[6px] shadow-[0_1px_2px_rgba(0,0,0,.18)]" />
            Liova
          </a>
          {links.map((link) => (
            <a key={link.href} href={link.href} className="hidden rounded-md px-2 py-0.5 font-medium hover:bg-ink/[0.06] lg:block">
              {link.label}
            </a>
          ))}
        </div>
        <div className="flex items-center gap-1">
          <a
            href={REPO} {...external}
            className="flex items-center gap-1.5 rounded-md px-2 py-0.5 font-medium hover:bg-ink/[0.06]"
            aria-label={stars === null ? "GitHub" : `GitHub, ${stars} stars`}
          >
            <Github size={14} />
            <span className="hidden xl:inline">GitHub</span>
            {stars !== null && (
              <span className="numeric flex items-center gap-0.5 text-ink-soft">
                <Star size={11} />
                {formatStars(stars)}
              </span>
            )}
          </a>
          <span className="hidden items-center gap-3 px-2 text-ink/80 lg:flex" aria-hidden="true">
            <Wifi size={14} />
            <Battery size={22} level={0.76} />
            <span className="numeric font-medium">
              {clock.toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" })}
            </span>
          </span>
          <a href={GET_IT} {...external} className="ml-1 rounded-md bg-ink px-2.5 py-0.5 font-semibold text-paper hover:bg-black">
            Get Liova
          </a>
        </div>
        <div className="pointer-events-none absolute inset-x-0 top-0 flex justify-center">
          <LiveNotch variant="notch" />
        </div>
      </nav>
    </motion.header>
  );
}

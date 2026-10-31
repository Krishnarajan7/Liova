import { AnimatePresence, motion } from "motion/react";
import { type ReactNode, useEffect, useState } from "react";
import { spring } from "../../site";
import { Back, Battery, Bolt, Calendar, Check, Download, Forward, Gauge, Gear, Hand, Headphones, Home, Pause, Play, Sparkle, Speaker, Timer, Tray } from "../Icons";
import type { Scene, SceneDetail } from "./director";
import { Artwork, formatTime, MusicWave, Ring, useTicker } from "./parts";

export type NotchShape = { width: number; height: number; radius: number };
export type NotchVariant = "notch" | "island";

/**
 * Sizes for each kind of content. `camera` is the width of the camera housing itself: on a
 * MacBook it's about an eighth of the screen's width, so the page passes one that fits.
 */
export function shapeFor(scene: Scene, variant: NotchVariant, camera: number): NotchShape {
  const island = variant === "island";
  const h = island ? 36 : 32;
  const ear = island ? 38 : 62;
  const round = (r: number) => (island ? Math.min(r * 1.4, 40) : r);
  switch (scene) {
    case "idle":
    case "demo":
      return { width: camera, height: h, radius: island ? h / 2 : 10 };
    case "lyrics":
      return { width: camera + ear * 2 + (island ? 24 : 84), height: h + 26, radius: round(16) };
    // Opened: the tab bar (32 px, or 38 on the island) plus the content and even padding.
    case "player":
      return { width: island ? 340 : 440, height: 132, radius: round(28) };
    case "download":
      return { width: island ? 340 : 440, height: island ? 130 : 124, radius: round(28) };
    case "agent-asking":
      return { width: island ? 350 : 470, height: island ? 172 : 166, radius: round(28) };
    case "agent-working":
    case "agent-done":
    case "run":
      return { width: camera + ear * 2 + (island ? 24 : 60), height: h + 26, radius: round(16) };
    default:
      return { width: camera + ear * 2, height: h, radius: island ? h / 2 : 12 };
  }
}

const fade = {
  initial: { opacity: 0, scale: 0.94, filter: "blur(5px)" },
  animate: {
    opacity: 1,
    scale: 1,
    filter: "blur(0px)",
    transition: { duration: 0.3, delay: 0.1, ease: [0.22, 1, 0.36, 1] },
  },
  exit: { opacity: 0, scale: 0.97, filter: "blur(3px)", transition: { duration: 0.12 } },
} as const;

/** The black shape: springs between sizes and cross-fades whatever it holds. */
export function NotchShell({
  shape,
  variant = "notch",
  contentKey,
  children,
}: {
  shape: NotchShape;
  variant?: NotchVariant;
  contentKey: string;
  children: ReactNode;
}) {
  const island = variant === "island";
  return (
    <motion.div
      className="relative bg-notch text-white"
      style={island ? { boxShadow: "0 10px 30px -12px rgba(0,0,0,.45)" } : undefined}
      initial={false}
      animate={{
        width: shape.width,
        height: shape.height,
        borderBottomLeftRadius: shape.radius,
        borderBottomRightRadius: shape.radius,
        borderTopLeftRadius: island ? shape.radius : 0,
        borderTopRightRadius: island ? shape.radius : 0,
      }}
      transition={spring}
    >
      {!island && (
        <>
          <Ear side="left" />
          <Ear side="right" />
        </>
      )}
      <div className="absolute inset-0 overflow-hidden" style={{ borderRadius: "inherit" }}>
        <AnimatePresence mode="popLayout" initial={false}>
          <motion.div key={contentKey} className="absolute inset-0" {...fade}>
            {children}
          </motion.div>
        </AnimatePresence>
      </div>
    </motion.div>
  );
}

/** The flared corners where a MacBook's notch meets the top edge of the screen. */
function Ear({ side }: { side: "left" | "right" }) {
  const r = 8;
  return (
    <span
      aria-hidden="true"
      className="pointer-events-none absolute top-0"
      style={{
        width: r,
        height: r,
        [side]: -r + 0.5,
        background: `radial-gradient(circle at ${side === "left" ? "0 100%" : "100% 100%"}, transparent ${r - 0.5}px, #000 ${r}px)`,
      }}
    />
  );
}

/** One scene's content. Sizes follow `shapeFor`. */
export function SceneContent({ scene, variant, detail = {} }: { scene: Scene; variant: NotchVariant; detail?: SceneDetail }) {
  const island = variant === "island";
  const ears = (left: ReactNode, right: ReactNode) => (
    <div className={`flex items-center justify-between ${island ? "h-[36px] px-[14px]" : "h-[32px] px-[18px]"}`}>
      <div className="flex w-[30px] justify-center">{left}</div>
      <div className="flex w-[30px] justify-center">{right}</div>
    </div>
  );
  const strip = (text: string) => (
    <p className="truncate px-4 text-center text-[12px] font-semibold tracking-[-0.01em] text-white/90">{text}</p>
  );

  switch (scene) {
    case "idle":
    case "demo":
      return null;
    case "lyrics":
      return (
        <div>
          {ears(<Artwork size={18} radius={5} />, <MusicWave />)}
          <LyricLine />
        </div>
      );
    case "player":
      return <Opened island={island}><Player compact={island} /></Opened>;
    case "charging":
      return (
        <div className="relative h-full">
          {ears(<Bolt size={15} className="text-leaf" />, <span className="numeric text-[13px] font-semibold text-leaf">76%</span>)}
          <motion.span
            aria-hidden="true"
            className="absolute bottom-0 h-[2px] w-16 rounded-full"
            style={{ background: "linear-gradient(90deg, transparent, #8bffab, transparent)" }}
            initial={{ left: "-20%" }}
            animate={{ left: "110%" }}
            transition={{ duration: 1.2, delay: 0.25, ease: [0.22, 1, 0.36, 1] }}
          />
        </div>
      );
    case "airpods":
      return ears(
        <Headphones size={15} className="text-white" />,
        <span className="numeric text-[12.5px] font-semibold text-leaf">82%</span>,
      );
    case "volume":
      return <LevelHUD island={island} />;
    case "download":
      return <Opened island={island}><DownloadOpen compact={island} /></Opened>;
    case "camera":
      return ears(<span className="size-[7px] rounded-full bg-leaf" />, <span className="size-[7px] rounded-full bg-ember" />);
    case "agent-working":
      return (
        <div>
          {ears(<Sparkle size={14} className="animate-pulse text-ember" />, <span className="size-[7px] rounded-full bg-ember" />)}
          <StatusLine text={detail.status ?? "Working"} />
        </div>
      );
    case "agent-done":
      return (
        <div>
          {ears(
            <Check size={14} className={detail.ok === false ? "text-rose" : "text-leaf"} />,
            <span className={`size-[7px] rounded-full ${detail.ok === false ? "bg-rose" : "bg-leaf"}`} />,
          )}
          {strip(detail.status ?? "Done")}
        </div>
      );
    case "agent-asking":
      return <Opened island={island}><AgentAsk compact={island} /></Opened>;
    case "run":
      return (
        <div>
          {ears(
            <Ring progress={detail.progress ?? 0} color="#0a84ff" size={15} />,
            <span className="numeric text-[12px] font-semibold text-sky">{Math.round((detail.progress ?? 0) * 100)}%</span>,
          )}
          {strip(detail.title ?? "Working")}
        </div>
      );
  }
}

/**
 * The opened notch, as in the app: its tabs on the left of the camera, battery and settings on
 * the right, and what's live underneath.
 */
function Opened({ island, children }: { island: boolean; children: ReactNode }) {
  const tabs = [Tray, Timer, Calendar, Gauge];
  return (
    <div className="flex h-full flex-col">
      <div className={`flex shrink-0 items-center justify-between text-white/60 ${island ? "h-[38px] px-[16px] pt-1.5" : "h-[32px] px-[16px]"}`}>
        <div className="flex items-center gap-[7px]">
          <span className="grid size-[22px] place-items-center rounded-full bg-white/15 text-white">
            <Home size={12} />
          </span>
          {tabs.map((Tab, i) => (
            <Tab key={i} size={13} />
          ))}
        </div>
        <div className="flex items-center gap-[7px]">
          <span className="numeric text-[11px] font-semibold text-white">90%</span>
          <Battery size={20} level={0.9} className="text-white" />
          <Gear size={12} />
        </div>
      </div>
      <div className="min-h-0 flex-1">{children}</div>
    </div>
  );
}

function StatusLine({ text }: { text: string }) {
  return (
    <div className="relative h-[26px] overflow-hidden">
      <AnimatePresence mode="popLayout" initial={false}>
        <motion.p
          key={text}
          className="absolute inset-x-0 truncate px-4 text-center text-[12px] font-semibold text-white/90"
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8 }}
          transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
        >
          {text}
        </motion.p>
      </AnimatePresence>
    </div>
  );
}

const lyrics = [
  "Under the neon, we were golden",
  "Running red lights through the rain",
  "Every window singing back our names",
  "Hold on, the night is young again",
];

function LyricLine() {
  const [line, setLine] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setLine((l) => (l + 1) % lyrics.length), 2200);
    return () => window.clearInterval(id);
  }, []);
  return <StatusLine text={lyrics[line]!} />;
}

function LevelHUD({ island }: { island: boolean }) {
  const level = useTicker(0.35, 0.7, 700);
  return (
    <div className={`flex items-center justify-between ${island ? "h-[36px] px-[16px]" : "h-[32px] px-[22px]"}`}>
      <Speaker size={15} />
      <div className="h-[5px] w-[44px] overflow-hidden rounded-full bg-white/20">
        <div className="h-full rounded-full bg-white" style={{ width: `${level * 100}%` }} />
      </div>
    </div>
  );
}

function Player({ compact }: { compact: boolean }) {
  const [playing, setPlaying] = useState(true);
  const elapsed = useTicker(83, 160, 77000, playing);
  return (
    <div className={`flex h-full items-center ${compact ? "px-[18px] pb-1" : "px-[22px] pb-1"}`}>
      <div className="flex w-full items-center gap-4">
        <Artwork size={compact ? 56 : 62} radius={13} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-[15px] font-semibold leading-tight">Golden Hour</p>
          <p className="truncate text-[13px] leading-tight text-white/55">The Midnight Owls</p>
          <div className="mt-2.5 h-[4px] overflow-hidden rounded-full bg-white/15">
            <div className="h-full rounded-full bg-white/85" style={{ width: `${(elapsed / 240) * 100}%` }} />
          </div>
          <div className="numeric mt-1 flex justify-between text-[10.5px] font-medium text-white/45">
            <span>{formatTime(elapsed)}</span>
            <span>-{formatTime(240 - elapsed)}</span>
          </div>
        </div>
        <div className="flex items-center gap-3 pl-1">
          {!compact && <Back size={17} />}
          <button
            type="button"
            aria-label={playing ? "Pause" : "Play"}
            className="grid size-8 place-items-center rounded-full transition hover:bg-white/10"
            onClick={() => setPlaying((p) => !p)}
          >
            {playing ? <Pause size={19} /> : <Play size={19} />}
          </button>
          <Forward size={17} />
        </div>
      </div>
    </div>
  );
}

function DownloadOpen({ compact }: { compact: boolean }) {
  const progress = useTicker(0.4, 0.95, 5000);
  return (
    <div className={`flex h-full items-center ${compact ? "px-[18px] pb-1" : "px-[22px] pb-1"}`}>
      <div className="w-full">
        <div className="flex items-center gap-2">
          <Download size={14} className="text-sky" />
          <p className="flex-1 truncate text-[15px] font-semibold">Liova-0.1.0.dmg</p>
          <p className="numeric text-[12px] text-white/50">24.6 MB/s</p>
        </div>
        <div className="mt-3 h-[6px] overflow-hidden rounded-full bg-white/15">
          <div className="h-full rounded-full bg-sky" style={{ width: `${progress * 100}%` }} />
        </div>
        <p className="numeric mt-1.5 text-[11px] text-white/45">{(progress * 18.4).toFixed(1)} of 18.4 MB · 2 s left</p>
      </div>
    </div>
  );
}

function AgentAsk({ compact }: { compact: boolean }) {
  return (
    <div className={`flex h-full flex-col justify-center ${compact ? "px-[18px] pb-1" : "px-[22px] pb-1"}`}>
      <div className="flex items-center gap-2">
        <Hand size={16} className="text-ember" />
        <p className="flex-1 truncate text-[14px] font-semibold">Your agent wants to run</p>
      </div>
      <pre className="mt-2 overflow-hidden rounded-[10px] bg-white/[0.08] px-3 py-2 font-mono text-[11.5px] text-white/85">
        git push origin main
      </pre>
      <div className="mt-2.5 flex items-center justify-end gap-2">
        <span className="flex-1 truncate text-[12px] text-white/40">Or answer in Terminal</span>
        <span className="rounded-full bg-[#6b1f1f] px-4 py-1.5 text-[12.5px] font-semibold">Deny</span>
        <span className="rounded-full bg-white px-4 py-1.5 text-[12.5px] font-semibold text-black">Allow</span>
      </div>
    </div>
  );
}

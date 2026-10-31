import { MotionConfig } from "motion/react";
import { Closeup } from "./components/Closeup";
import type { Scene } from "./components/notch/director";

/**
 * One notch state, up close, for README and social images (`site/scripts/capture-stills.sh`
 * screenshots these). Open `?still=player` and so on.
 */
export const stills: Record<string, Scene> = {
  music: "lyrics",
  player: "player",
  agent: "agent-asking",
  charging: "charging",
  download: "download",
  airpods: "airpods",
};

export function Still({ name }: { name: string }) {
  if (name === "og") return <OgCard />;
  return (
    <MotionConfig reducedMotion="always">
      <div className="w-[1200px] bg-paper">
        <Closeup scene={stills[name] ?? "player"} className="!rounded-none !shadow-none" />
      </div>
    </MotionConfig>
  );
}

/** The link preview for social sites: 1200 by 630. */
function OgCard() {
  return (
    <MotionConfig reducedMotion="always">
      <div className="flex h-[630px] w-[1200px] items-center gap-12 bg-paper px-16">
        <div className="flex-1">
          <div className="flex items-center gap-3">
            <img src="icon.png" alt="" className="size-[52px] rounded-[13px] shadow" />
            <span className="text-[30px] font-bold tracking-[-0.02em]">Liova</span>
          </div>
          <h1 className="display mt-8 text-[76px]">
            Your notch,
            <br />
            finally{" "}
            <span className="relative inline-block">
              useful.
              <svg className="absolute -bottom-3 left-0 h-6 w-full" viewBox="0 0 300 20" preserveAspectRatio="none" aria-hidden="true">
                <path d="M4 14 C 60 6, 120 4, 180 8 S 270 14, 296 6" fill="none" stroke="var(--color-pen)" strokeWidth="5" strokeLinecap="round" />
              </svg>
            </span>
          </h1>
          <p className="mt-6 whitespace-nowrap text-[24px] text-ink-soft">Free · Open source · 0% idle CPU</p>
        </div>
        <div className="w-[470px]">
          <Closeup scene="player" />
        </div>
      </div>
    </MotionConfig>
  );
}

import { useLayoutEffect, useRef, useState } from "react";
import { Battery, Wifi } from "./Icons";
import type { Scene, SceneDetail } from "./notch/director";
import { NotchShell, SceneContent, shapeFor } from "./notch/Notch";
import { Wallpaper } from "./Wallpaper";

/** The design size of the close-up; it's scaled as a whole to its container. */
const DESIGN = { width: 760, height: 320 };

/**
 * The top of a Mac's screen, up close: wallpaper, menu bar and the notch showing `scene`,
 * magnified so its details read on any device.
 */
export function Closeup({ scene, detail, className = "" }: { scene: Scene; detail?: SceneDetail; className?: string }) {
  const frame = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);
  useLayoutEffect(() => {
    const element = frame.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => entry && setScale(entry.contentRect.width / DESIGN.width));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const shown = scene === "demo" ? "idle" : scene;

  return (
    <div
      ref={frame}
      className={`relative w-full overflow-hidden rounded-[clamp(18px,3vw,32px)] shadow-[0_30px_80px_-30px_rgba(20,24,64,.55),0_0_0_1px_rgba(0,0,0,.08)] ${className}`}
      style={{ aspectRatio: `${DESIGN.width} / ${DESIGN.height}` }}
    >
      <div
        className="absolute left-0 top-0 origin-top-left"
        style={{ width: DESIGN.width, height: DESIGN.height, transform: `scale(${scale})` }}
      >
        <Wallpaper className="absolute inset-0 h-full w-full" />
        <div
          aria-hidden="true"
          className="absolute inset-x-0 top-0 flex h-8 items-center justify-between bg-black/15 px-4 text-[12.5px] font-medium text-white backdrop-blur-md"
        >
          <div className="flex gap-4">
            <span className="font-bold">Music</span>
            <span>File</span>
            <span>Edit</span>
          </div>
          <div className="flex items-center gap-3">
            <Wifi size={13} />
            <Battery size={20} level={0.76} />
          </div>
        </div>
        <div className="absolute inset-x-0 top-0 flex justify-center">
          <NotchShell shape={shapeFor(shown, "notch", 150)} contentKey={shown}>
            <SceneContent scene={shown} variant="notch" detail={detail} />
          </NotchShell>
        </div>
      </div>
    </div>
  );
}

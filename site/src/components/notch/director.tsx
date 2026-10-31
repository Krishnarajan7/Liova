import { useInView } from "motion/react";
import { createContext, type ReactNode, type RefObject, useCallback, useContext, useEffect, useMemo, useState } from "react";

/** Everything the notch knows how to show. */
export type Scene =
  | "demo"
  | "idle"
  | "lyrics"
  | "player"
  | "charging"
  | "airpods"
  | "volume"
  | "download"
  | "agent-working"
  | "agent-asking"
  | "agent-done"
  | "camera"
  | "run";

/** Extra live values a scene can carry (agent status line, a script's progress). */
export type SceneDetail = { status?: string; progress?: number; title?: string; ok?: boolean };

type Director = {
  scene: Scene;
  detail: SceneDetail;
  /** Sections claim the notch while they sit across the middle of the screen. */
  claim: (owner: string, scene: Scene, detail?: SceneDetail) => void;
  release: (owner: string) => void;
};

const Context = createContext<Director | null>(null);

/**
 * The page's own notch, at the top of the screen, shows whatever the section you're reading
 * is about. The most recent claim wins; releasing falls back to the one before it.
 */
export function NotchDirector({ children }: { children: ReactNode }) {
  const [claims, setClaims] = useState<{ owner: string; scene: Scene; detail: SceneDetail }[]>([]);
  // Stable, so sections can claim from effects without re-running them.
  const claim = useCallback((owner: string, scene: Scene, detail: SceneDetail = {}) => {
    setClaims((list) => {
      const last = list[list.length - 1];
      if (last?.owner === owner && last.scene === scene && JSON.stringify(last.detail) === JSON.stringify(detail)) {
        return list;
      }
      return [...list.filter((c) => c.owner !== owner), { owner, scene, detail }];
    });
  }, []);
  const release = useCallback((owner: string) => {
    setClaims((list) => (list.some((c) => c.owner === owner) ? list.filter((c) => c.owner !== owner) : list));
  }, []);
  const director = useMemo<Director>(() => {
    const top = claims[claims.length - 1];
    return { scene: top?.scene ?? "demo", detail: top?.detail ?? {}, claim, release };
  }, [claims, claim, release]);
  return <Context.Provider value={director}>{children}</Context.Provider>;
}

export function useDirector() {
  const director = useContext(Context);
  if (!director) throw new Error("useDirector outside NotchDirector");
  return director;
}

/** While `ref` crosses the middle of the viewport, the top notch shows `scene`. */
export function useNotchScene(owner: string, ref: RefObject<Element | null>, scene: Scene, detail?: SceneDetail) {
  const { claim, release } = useDirector();
  const active = useInView(ref, { margin: "-45% 0px -45% 0px" });
  const key = JSON.stringify(detail ?? {});
  useEffect(() => {
    if (active) claim(owner, scene, detail);
    else release(owner);
  }, [active, owner, scene, key, claim, release]); // detail is compared through `key`
  useEffect(() => () => release(owner), [owner, release]);
  return active;
}

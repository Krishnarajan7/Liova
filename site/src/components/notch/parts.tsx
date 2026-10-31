import { motion, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

/** Album art stand-in: the same plum-to-rose gradient Liova's own previews use. */
export function Artwork({ size, radius, hue = "plum" }: { size: number; radius: number; hue?: "plum" | "sun" | "sea" }) {
  const fills = {
    plum: "linear-gradient(135deg, #6d5bd0 0%, #b3569b 55%, #ff6f7d 100%)",
    sun: "linear-gradient(135deg, #ffb347 0%, #ff6a3d 60%, #d63a6a 100%)",
    sea: "linear-gradient(135deg, #2dd4bf 0%, #0a84ff 60%, #5e5ce6 100%)",
  };
  return (
    <div
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        borderRadius: radius,
        background: fills[hue],
        boxShadow: "inset 0 0 0 0.5px rgba(255,255,255,.18)",
      }}
    />
  );
}

/**
 * The music wave from the closed notch: one line rippling under an envelope that pins its ends,
 * the same formula as the app (MusicWaveView.offsets). Tinted like the album art (the plum
 * stand-in's rose); holds still as a soft curve when paused or with reduced motion.
 */
export function MusicWave({
  playing = true,
  color = "#ff7aa8",
  width = 22,
  height = 12,
}: {
  playing?: boolean;
  color?: string;
  width?: number;
  height?: number;
}) {
  const path = useRef<SVGPathElement>(null);
  const still = useReducedMotion();
  useEffect(() => {
    const draw = (time: number, scale = 1) => path.current?.setAttribute("d", wavePath(time, width, height, scale));
    if (!playing || still) {
      draw(0.9, 0.45);
      return;
    }
    let frame = 0;
    const start = performance.now();
    const tick = (now: number) => {
      draw((now - start) / 1000);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [playing, still, width, height]);
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} fill="none" className="overflow-visible">
      <path ref={path} stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function wavePath(time: number, width: number, height: number, scale: number) {
  const count = 24;
  const line = 2;
  const amplitude = 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(time * 1.3)) * (0.6 + 0.4 * Math.sin(time * 2.1 + 0.7));
  const points = Array.from({ length: count }, (_, i) => {
    const x = i / (count - 1);
    const envelope = Math.pow(Math.sin(Math.PI * x), 1.5);
    const wave = 0.6 * Math.sin(2 * Math.PI * 1.6 * x - time * 4.2) + 0.4 * Math.sin(2 * Math.PI * 2.7 * x + time * 2.9 + 1.3);
    const offset = Math.max(-1, Math.min(1, envelope * amplitude * wave)) * scale;
    return [line / 2 + x * (width - line), height / 2 + offset * (height / 2 - line / 2)] as const;
  });
  // Through the midpoints, each sample a control point: smooth, no overshoot.
  let d = `M${points[0]![0].toFixed(2)} ${points[0]![1].toFixed(2)}`;
  for (let i = 1; i < count - 1; i++) {
    const [x, y] = points[i]!;
    const [nx, ny] = points[i + 1]!;
    d += ` Q${x.toFixed(2)} ${y.toFixed(2)} ${((x + nx) / 2).toFixed(2)} ${((y + ny) / 2).toFixed(2)}`;
  }
  const last = points[count - 1]!;
  return `${d} L${last[0].toFixed(2)} ${last[1].toFixed(2)}`;
}

/** A determinate ring, as in the closed notch. */
export function Ring({ progress, color, size = 16, stroke = 2.5 }: { progress: number; color: string; size?: number; stroke?: number }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true" className="-rotate-90">
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeOpacity={0.25} strokeWidth={stroke} />
      <motion.circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke={color}
        strokeWidth={stroke}
        strokeLinecap="round"
        strokeDasharray={c}
        animate={{ strokeDashoffset: c * (1 - progress) }}
        transition={{ duration: 0.4, ease: "linear" }}
      />
    </svg>
  );
}

/** Counts up while mounted, for progress that should feel live. */
export function useTicker(from: number, to: number, durationMs: number, active = true) {
  const [value, setValue] = useState(from);
  useEffect(() => {
    if (!active) return;
    const start = performance.now();
    let frame = 0;
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs);
      setValue(from + (to - from) * t);
      if (t < 1) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [from, to, durationMs, active]);
  return value;
}

export function formatTime(seconds: number) {
  const s = Math.max(0, Math.round(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

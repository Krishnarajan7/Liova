import { motion } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Play } from "../components/Icons";
import { useNotchScene } from "../components/notch/director";
import { Note, Reveal, SectionHeader } from "../components/ui";
import { PLUGIN_API, external } from "../site";

const commands = [
  { id: "deploy", label: "Deploy", title: "Deploying", code: 'liova activity start --id deploy --title "Deploying" --progress 0.1' },
  { id: "render", label: "Render", title: "Rendering film", code: 'liova activity start --id render --title "Rendering film" --progress 0.1' },
  { id: "backup", label: "Backup", title: "Backing up", code: 'liova activity start --id backup --title "Backing up" --progress 0.1' },
];

/** Run a real `liova` command and the notch at the top of this page shows it. */
export function Scriptable() {
  const section = useRef<HTMLElement>(null);
  const [selected, setSelected] = useState(0);
  const [progress, setProgress] = useState<number | null>(null);
  const command = commands[selected]!;

  useEffect(() => {
    if (progress === null) return;
    if (progress >= 1) {
      const id = window.setTimeout(() => setProgress(null), 1600);
      return () => window.clearTimeout(id);
    }
    const id = window.setTimeout(() => setProgress((p) => Math.min(1, (p ?? 0) + 0.05)), 140);
    return () => window.clearTimeout(id);
  }, [progress]);

  const running = progress !== null;
  useNotchScene(
    "script",
    section,
    running ? "run" : "idle",
    running ? { progress, title: progress >= 1 ? "Done" : command.title } : undefined,
  );

  return (
    <section ref={section} className="bg-paper-deep/60 px-5 py-[clamp(96px,14vh,160px)]">
      <SectionHeader
        label="Scriptable"
        title="Anything can light up the notch."
        body="Builds, deploys, renders, backups: one command from any script, a local socket or a liova:// link."
      />
      <Reveal delay={0.1} className="relative mx-auto mt-12 max-w-[760px]">
        <Note arrow="left" text="try me!" className="-right-[150px] bottom-[86px] hidden xl:flex" delay={0.4} size={24} />
        <div className="overflow-hidden rounded-[22px] bg-[#141416] shadow-[0_30px_60px_-30px_rgba(0,0,0,.6)]">
          <div className="flex flex-wrap gap-1.5 border-b border-white/[0.06] px-3 py-3">
            {commands.map((c, index) => (
              <button
                type="button"
                key={c.id}
                onClick={() => {
                  setSelected(index);
                  setProgress(null);
                }}
                className={`rounded-full px-3.5 py-1.5 text-[13px] font-semibold transition ${
                  index === selected ? "bg-white text-ink" : "text-white/55 hover:bg-white/10 hover:text-white"
                }`}
              >
                {c.label}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-3 px-5 py-4">
            <code className="flex-1 overflow-x-auto whitespace-nowrap font-mono text-[13px] text-white/80 [scrollbar-width:none]">
              <span className="text-[#ffb36b]">$ </span>
              {command.code}
            </code>
            <motion.button
              type="button"
              whileTap={{ scale: 0.94 }}
              onClick={() => setProgress(0.1)}
              disabled={running}
              className="flex shrink-0 items-center gap-1.5 rounded-full bg-ember px-4 py-2 text-[13.5px] font-semibold text-white transition hover:brightness-110 disabled:opacity-50"
            >
              <Play size={12} />
              Run
            </motion.button>
          </div>
        </div>
        <p className="mt-5 text-center text-[15px] text-ink-soft">
          {running ? "Look up ↑ the notch is showing it." : "Press Run, then look at the notch at the top of this page."}{" "}
          <a href={PLUGIN_API} {...external} className="font-semibold text-ink underline decoration-ink/25 underline-offset-4 hover:decoration-ink">
            Plugin API
          </a>
        </p>
      </Reveal>
    </section>
  );
}

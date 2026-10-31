import { motion, useInView } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Closeup } from "../components/Closeup";
import { type Scene, type SceneDetail, useNotchScene } from "../components/notch/director";
import { Marker, Note, Reveal, SectionHeader } from "../components/ui";
import { AGENT_ISLAND, external } from "../site";

type Line = { text: string; tone: "you" | "tool" | "ok" | "ask"; status?: string };

const session: Line[] = [
  { text: "› Fix the flaky upload test and push it", tone: "you" },
  { text: "  Reading Tests/UploadTests.swift", tone: "tool", status: "Reading UploadTests.swift" },
  { text: "  Editing Sources/Upload/Retry.swift", tone: "tool", status: "Editing Retry.swift" },
  { text: "  Running swift test", tone: "tool", status: "Running swift test" },
  { text: "  ✓ 729 tests passed", tone: "ok", status: "729 tests passed" },
  { text: "  Wants to run: git push origin main", tone: "ask" },
];

const agents = ["Claude Code", "Codex", "Gemini CLI", "Cursor"];

export function Agents() {
  const section = useRef<HTMLElement>(null);
  const live = useInView(section, { margin: "-20% 0px" });
  const [shown, setShown] = useState(1);
  const [answer, setAnswer] = useState<"allow" | "deny" | null>(null);

  // Type the session out line by line, wait at the question, start over after the answer.
  useEffect(() => {
    if (!live) return;
    if (shown < session.length) {
      const id = window.setTimeout(() => setShown((n) => n + 1), shown === 1 ? 1000 : 1300);
      return () => window.clearTimeout(id);
    }
    if (answer) {
      const id = window.setTimeout(() => {
        setAnswer(null);
        setShown(1);
      }, 3800);
      return () => window.clearTimeout(id);
    }
    // Nobody answered: play it out so the demo keeps moving.
    const id = window.setTimeout(() => setAnswer("allow"), 9000);
    return () => window.clearTimeout(id);
  }, [live, shown, answer]);

  const last = session[shown - 1]!;
  let scene: Scene = "idle";
  let detail: SceneDetail = {};
  if (answer) {
    scene = "agent-done";
    detail = { status: answer === "allow" ? "Pushed to main" : "Push denied", ok: answer === "allow" };
  } else if (last.tone === "ask") {
    scene = "agent-asking";
  } else if (last.status) {
    scene = "agent-working";
    detail = { status: last.status };
  }
  useNotchScene("agents", section, scene, detail);
  const asking = scene === "agent-asking";

  return (
    <section id="agents" ref={section} className="px-5 py-[clamp(96px,14vh,160px)]">
      <SectionHeader
        label="Agent Island"
        title={
          <>
            Your agents, <Marker>one glance</Marker> away.
          </>
        }
        body="See what your coding agent is doing while you work in another window, and answer its questions from the notch. Ignore it, and it simply asks in the terminal as usual."
      />
      <Reveal delay={0.1} className="mx-auto mt-14 max-w-[820px]">
        <Closeup scene={scene} detail={detail} />
        <div className="relative mt-4">
          <Note arrow="left" text="go on, answer it" className="-right-[190px] bottom-1 hidden xl:flex" delay={0.3} />
          <div className="overflow-hidden rounded-[22px] bg-[#141416] text-[13px] shadow-[0_30px_60px_-30px_rgba(0,0,0,.6)]">
          <div className="flex items-center gap-1.5 border-b border-white/[0.06] px-4 py-3">
            <span className="size-[11px] rounded-full bg-[#ff5f57]" />
            <span className="size-[11px] rounded-full bg-[#febc2e]" />
            <span className="size-[11px] rounded-full bg-[#28c840]" />
            <span className="ml-3 font-medium text-white/40">uploader — zsh</span>
          </div>
          <div className="min-h-[230px] whitespace-pre-wrap px-5 py-4 font-mono leading-[1.95]">
            {session.slice(0, shown).map((line, i) => (
              <motion.p
                key={i}
                initial={{ opacity: 0, x: -6 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.3 }}
                className={
                  line.tone === "you"
                    ? "text-white"
                    : line.tone === "ok"
                      ? "text-[#5fe08a]"
                      : line.tone === "ask"
                        ? "text-[#ffb36b]"
                        : "text-white/50"
                }
              >
                {line.text}
              </motion.p>
            ))}
            {answer && (
              <motion.p initial={{ opacity: 0 }} animate={{ opacity: 1 }} className={answer === "allow" ? "text-[#5fe08a]" : "text-[#ff6b81]"}>
                {answer === "allow" ? "  ✓ Allowed from the notch · pushed 1 commit" : "  ✕ Denied from the notch · nothing ran"}
              </motion.p>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-2 border-t border-white/[0.06] px-4 py-3">
            <p className="flex-1 text-[13px] text-white/45">{asking ? "Answer it, like you would in the notch:" : "Waiting for the agent…"}</p>
            <button
              type="button"
              disabled={!asking}
              onClick={() => setAnswer("deny")}
              className="rounded-full bg-[#6b1f1f] px-4 py-1.5 text-[13px] font-semibold text-white transition hover:brightness-125 disabled:opacity-30"
            >
              Deny
            </button>
            <button
              type="button"
              disabled={!asking}
              onClick={() => setAnswer("allow")}
              className="rounded-full bg-white px-4 py-1.5 text-[13px] font-semibold text-black transition hover:bg-white/85 disabled:opacity-30"
            >
              Allow
            </button>
          </div>
          </div>
        </div>
      </Reveal>
      <Reveal delay={0.15} className="mx-auto mt-10 max-w-2xl text-center">
        <p className="text-[15px] text-ink-soft">
          Works with{" "}
          {agents.map((agent, i) => (
            <span key={agent}>
              <strong className="font-semibold text-ink">{agent}</strong>
              {i < agents.length - 2 ? ", " : i === agents.length - 2 ? " and " : ""}
            </span>
          ))}
          . One click to connect in Settings. Only the event, the folder name and a short tool summary reach the notch,
          never your prompts.{" "}
          <a href={AGENT_ISLAND} {...external} className="font-semibold text-ink underline decoration-ink/25 underline-offset-4 hover:decoration-ink">
            Exactly what's sent
          </a>
        </p>
      </Reveal>
    </section>
  );
}

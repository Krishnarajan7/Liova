import { useRef } from "react";
import type { ReactNode } from "react";
import { Eye, Leaf, Lock, Terminal } from "../components/Icons";
import { useNotchScene } from "../components/notch/director";
import { Reveal, SectionHeader } from "../components/ui";
import { PRIVACY, external } from "../site";

const points: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <Eye size={20} />,
    title: "No telemetry. Ever.",
    body: "No analytics, no crash reporters, no accounts. Once a day it asks GitHub if there's a new version, and you can turn that off.",
  },
  {
    icon: <Lock size={20} />,
    title: "Permissions only when needed",
    body: "Each one is asked for when you turn on the feature that needs it. Accessibility reads the volume keys, never what you type.",
  },
  {
    icon: <Terminal size={20} />,
    title: "Your prompts stay put",
    body: "Agent Island sees the event, the folder name and a short tool summary. Never your prompt text.",
  },
  {
    icon: <Leaf size={20} />,
    title: "Open, so you can check",
    body: "Every line is on GitHub under the MIT license. Plugins run outside the app, and nothing freezes system processes.",
  },
];

export function Privacy() {
  const section = useRef<HTMLElement>(null);
  // While you read about privacy, the notch shows what it does when an app turns on the camera.
  useNotchScene("privacy", section, "camera");
  return (
    <section id="privacy" ref={section} className="relative py-[clamp(96px,14vh,160px)]">
      <div className="mx-auto max-w-6xl px-5">
        <SectionHeader label="Private by default" title="What happens on your Mac stays on your Mac." />
        <div className="mt-16 grid gap-4 sm:grid-cols-2">
          {points.map((point, index) => (
            <Reveal key={point.title} delay={index * 0.06}>
              <article className="h-full rounded-[24px] bg-card p-8 shadow-[0_1px_0_rgba(0,0,0,.04),0_0_0_1px_rgba(0,0,0,.07)]">
                <span className="grid size-11 place-items-center rounded-2xl bg-ember/10 text-ember">{point.icon}</span>
                <h3 className="mt-6 text-[20px] font-semibold tracking-[-0.02em]">{point.title}</h3>
                <p className="mt-2 text-[15.5px] leading-relaxed text-ink-soft">{point.body}</p>
              </article>
            </Reveal>
          ))}
        </div>
        <Reveal delay={0.2} className="mt-8 text-center">
          <a href={PRIVACY} {...external} className="text-[14px] font-medium text-ink-soft underline-offset-4 hover:text-ink hover:underline">
            The full privacy notes →
          </a>
        </Reveal>
      </div>
    </section>
  );
}

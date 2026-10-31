import { motion } from "motion/react";
import type { ReactNode } from "react";
import { Calendar, Chip, Eye, Rain, Speaker, Terminal, Timer, Tray } from "../components/Icons";
import { Note, Reveal, SectionHeader } from "../components/ui";

const items: { icon: ReactNode; title: [string, string]; note: string }[] = [
  { icon: <Tray size={44} />, title: ["File Shelf", "and AirDrop"], note: "Drop files on the notch, drag them out anywhere." },
  { icon: <Speaker size={44} />, title: ["Volume and", "brightness HUDs"], note: "Slim bars at the screen's edge, or in the notch." },
  { icon: <Timer size={44} />, title: ["Timers you", "can see"], note: "Start one in a tap, watch it count down." },
  { icon: <Calendar size={44} />, title: ["Your next", "meeting"], note: "Ten minutes early, with a Join button." },
  { icon: <Rain size={44} />, title: ["Rain,", "before it starts"], note: "Opt-in weather with a heads-up." },
  { icon: <Eye size={44} />, title: ["Camera and", "mic alerts"], note: "Lights up the moment any app turns them on." },
  { icon: <Chip size={44} />, title: ["System", "at a glance"], note: "CPU, memory and GPU, measured only while you look." },
  { icon: <Terminal size={44} />, title: ["Scriptable", "from anywhere"], note: "A CLI, a local socket and liova:// links." },
];

export function More() {
  return (
    <section className="px-5 py-[clamp(96px,14vh,160px)]">
      <SectionHeader label="And there's more" title="Small things, done properly." />
      <div className="relative mx-auto mt-16 grid max-w-5xl grid-cols-2 gap-x-6 gap-y-14 sm:grid-cols-4">
        <Note arrow="down" arrowFirst={false} text="everyone's favourite" className="-left-[120px] -top-12 hidden xl:flex" delay={0.5} rotate={-8} />
        {items.map((item, index) => (
          <Reveal key={item.title.join(" ")} delay={(index % 4) * 0.08} className="text-center">
            <motion.div
              className="mx-auto grid size-16 place-items-center text-ink"
              whileHover={{ rotate: [0, -8, 6, -3, 0], scale: 1.08 }}
              transition={{ duration: 0.6 }}
            >
              {item.icon}
            </motion.div>
            <h3 className="display mt-5 text-[clamp(1.15rem,1.9vw,1.45rem)] leading-tight">
              {item.title[0]}
              <br />
              {item.title[1]}
            </h3>
            <p className="mx-auto mt-2 max-w-[13rem] text-[14px] leading-snug text-ink-soft">{item.note}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

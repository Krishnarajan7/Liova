import { motion } from "motion/react";
import type { ReactNode } from "react";
import { Calendar, Clipboard, Flame, Headphones, Keys, Phone, Rain, Speaker, Tray } from "../components/Icons";
import { Note, Reveal, SectionHeader } from "../components/ui";

const items: { icon: ReactNode; title: [string, string]; note: string }[] = [
  { icon: <Tray size={44} />, title: ["File Shelf", "and AirDrop"], note: "Drop files on the notch, drag them out anywhere." },
  { icon: <Speaker size={44} />, title: ["Volume and", "brightness HUDs"], note: "A pill at the screen's edge, a line of light, or in the notch." },
  { icon: <Headphones size={44} />, title: ["Speakers", "or AirPods"], note: "Choose where sound goes, and which mic, from the notch." },
  { icon: <Clipboard size={44} />, title: ["Clipboard", "history"], note: "Your last 30 copies, a click away. Never passwords." },
  { icon: <Calendar size={44} />, title: ["Your next", "meeting"], note: "Ten minutes early, with a Join button." },
  { icon: <Rain size={44} />, title: ["Rain,", "before it starts"], note: "Opt-in weather. Watch it fall in the notch." },
  { icon: <Phone size={44} />, title: ["Calls,", "from the notch"], note: "Mute or hang up WhatsApp, Zoom or Meet in one click." },
  { icon: <Flame size={44} />, title: ["What's heating", "your Mac"], note: "Names the app eating CPU or memory, and quits it." },
  { icon: <Keys size={44} />, title: ["Shortcuts", "from anywhere"], note: "⌃⌥N opens the notch, ⌃⌥V your clipboard." },
];

/** What can be changed in Settings. The first option in each row is how Liova arrives. */
const choices: { what: string; options: string[] }[] = [
  { what: "Volume and brightness", options: ["Side bar", "Edge light", "In the notch"] },
  { what: "The notch's look", options: ["Black", "Glass"] },
  { what: "It opens", options: ["On hover", "On click"] },
  { what: "The music wave moves", options: ["Always", "When plugged in", "Never"] },
  { what: "It shows on", options: ["All displays", "Built-in display", "Main display"] },
];

export function More() {
  return (
    <section className="px-5 py-[clamp(96px,14vh,160px)]">
      <SectionHeader label="And there's more" title="Small things, done properly." />
      <div className="relative mx-auto mt-16 flex max-w-5xl flex-wrap justify-center gap-x-6 gap-y-14">
        <Note arrow="down" arrowFirst={false} text="everyone's favourite" className="-left-[120px] -top-12 hidden xl:flex" delay={0.5} rotate={-8} />
        {items.map((item, index) => (
          <Reveal key={item.title.join(" ")} delay={(index % 4) * 0.08} className="w-[calc(50%-12px)] text-center sm:w-[calc(25%-18px)]">
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

      <Reveal className="mx-auto mt-24 max-w-3xl">
        <p className="label text-center">Not just the defaults</p>
        <h3 className="display mt-3 text-center text-[clamp(1.7rem,3.4vw,2.5rem)]">Set it up your way.</h3>
        <p className="mx-auto mt-4 max-w-xl text-center text-[clamp(1rem,1.4vw,1.1rem)] leading-relaxed text-ink-soft">
          What you see on this page is only how Liova arrives. Each of these is a choice in Settings, and every feature
          has its own switch.
        </p>
        <dl className="mt-9 divide-y divide-line border-y border-line">
          {choices.map((choice) => (
            <div key={choice.what} className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2.5 py-3.5">
              <dt className="text-[15px] font-medium text-ink">{choice.what}</dt>
              <dd className="flex flex-wrap gap-2">
                {choice.options.map((option, index) => (
                  <span
                    key={option}
                    className={
                      index === 0
                        ? "rounded-full bg-ink px-3 py-1 text-[13px] font-medium text-paper"
                        : "rounded-full border border-line px-3 py-1 text-[13px] text-ink-soft"
                    }
                  >
                    {option}
                    {index === 0 && <span className="sr-only"> (how it starts)</span>}
                  </span>
                ))}
              </dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-center text-[13px] text-ink-faint">Filled is how it starts. Change any of them in Settings.</p>
      </Reveal>
    </section>
  );
}

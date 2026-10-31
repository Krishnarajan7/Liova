import { AnimatePresence, motion } from "motion/react";
import { type ReactNode, useState } from "react";
import { Plus } from "../components/Icons";
import { Reveal, SectionHeader } from "../components/ui";
import { DISCUSSIONS, external } from "../site";

const faqs: { q: string; a: ReactNode }[] = [
  {
    q: "Is it really free?",
    a: "Yes. Liova is open source under the MIT license: no trial, no subscription, no paid tier. If it makes your day better, a star on GitHub helps more people find it.",
  },
  {
    q: "Does my Mac need a notch?",
    a: "No. On notched MacBooks Liova matches the camera housing exactly. On every other Mac and on external displays it draws a notch of its own, one per display.",
  },
  {
    q: "Will it drain my battery?",
    a: "It's built not to. Liova uses no CPU while there's nothing to show, the music wave rests when paused or in Low Power Mode, and every number we claim is measured and published.",
  },
  {
    q: "Which macOS versions?",
    a: "macOS 14 Sonoma or later, on Apple Silicon and Intel. One universal app.",
  },
  {
    q: "Why does macOS say it can't verify Liova?",
    a: (
      <>
        Liova isn't notarized yet, which needs a paid Apple account. Open System Settings, then Privacy & Security, and click{" "}
        <em>Open Anyway</em>, once. Updates after that install themselves, and only when they're signed by Liova's own
        certificate.
      </>
    ),
  },
  {
    q: "How is it different from other notch apps?",
    a: "It's free and open, it shows your coding agents and lets you answer them, and performance is treated as a feature: measured on every change, published in the repo.",
  },
];

export function Faq() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section id="faq" className="relative bg-paper-deep/60 py-[clamp(96px,14vh,160px)]">
      <div className="mx-auto grid max-w-6xl gap-14 px-5 lg:grid-cols-[0.8fr_1.2fr]">
        <div>
          <SectionHeader
            align="left"
            label="Questions"
            title="Good to know."
            body={
              <>
                Something else?{" "}
                <a href={DISCUSSIONS} {...external} className="font-medium text-ink underline underline-offset-4">
                  Ask in Discussions
                </a>
                .
              </>
            }
          />
        </div>
        <Reveal delay={0.1}>
          <ul className="divide-y divide-line border-y border-line">
            {faqs.map((faq, index) => {
              const isOpen = open === index;
              return (
                <li key={faq.q}>
                  <button
                    type="button"
                    aria-expanded={isOpen}
                    onClick={() => setOpen(isOpen ? null : index)}
                    className="flex w-full items-center gap-5 py-6 text-left"
                  >
                    <span className="numeric w-7 text-[13px] font-semibold text-ink-faint">{String(index + 1).padStart(2, "0")}</span>
                    <span className="flex-1 text-[clamp(1.05rem,1.8vw,1.25rem)] font-semibold tracking-[-0.015em]">{faq.q}</span>
                    <motion.span
                      animate={{ rotate: isOpen ? 45 : 0 }}
                      transition={{ type: "spring", bounce: 0, duration: 0.4 }}
                      className="grid size-8 place-items-center rounded-full bg-ink/[0.05]"
                    >
                      <Plus size={14} />
                    </motion.span>
                  </button>
                  <AnimatePresence initial={false}>
                    {isOpen && (
                      <motion.div
                        initial={{ height: 0, opacity: 0 }}
                        animate={{ height: "auto", opacity: 1 }}
                        exit={{ height: 0, opacity: 0 }}
                        transition={{ type: "spring", bounce: 0, duration: 0.45 }}
                        className="overflow-hidden"
                      >
                        <p className="pb-7 pl-12 pr-12 text-[16px] leading-relaxed text-ink-soft">{faq.a}</p>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </li>
              );
            })}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}

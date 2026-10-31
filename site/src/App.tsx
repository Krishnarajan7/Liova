import { MotionConfig } from "motion/react";
import { MenuBar } from "./components/MenuBar";
import { NotchDirector } from "./components/notch/director";
import { Agents } from "./sections/Agents";
import { Faq } from "./sections/Faq";
import { Final, Footer } from "./sections/Final";
import { Hero } from "./sections/Hero";
import { More } from "./sections/More";
import { Numbers } from "./sections/Numbers";
import { Privacy } from "./sections/Privacy";
import { Scriptable } from "./sections/Scriptable";
import { Story } from "./sections/Story";
import { useSmoothScroll } from "./useSmoothScroll";

export function App() {
  useSmoothScroll();
  return (
    <MotionConfig reducedMotion="user">
      <NotchDirector>
        <a
          href="#story"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-12 focus:z-[60] focus:rounded-full focus:bg-ink focus:px-4 focus:py-2 focus:text-paper"
        >
          Skip to content
        </a>
        <MenuBar />
        <main>
          <Hero />
          <Story />
          <More />
          <Numbers />
          <Agents />
          <Scriptable />
          <Privacy />
          <Faq />
          <Final />
        </main>
        <Footer />
      </NotchDirector>
    </MotionConfig>
  );
}

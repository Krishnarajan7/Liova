import Lenis from "lenis";
import { useEffect } from "react";

const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

/** Inertial scrolling, off for anyone who asked for less motion. In-page links glide too. */
export function useSmoothScroll() {
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const lenis = new Lenis({ autoRaf: true, lerp: 0.1 });

    // Lenis's own `anchors` option doesn't stop the browser's jump to the hash, so the page
    // snaps before it can glide. Take the click over instead.
    const onClick = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = (event.target as Element | null)?.closest<HTMLAnchorElement>('a[href^="#"]');
      const hash = link?.getAttribute("href");
      if (!hash) return;
      const target = hash === "#" || hash === "#top" ? 0 : document.querySelector<HTMLElement>(hash);
      if (target === null) return;
      event.preventDefault();
      const top = typeof target === "number";
      // Longer trips take a little longer, but never drag.
      const distance = top ? window.scrollY : Math.abs(target.getBoundingClientRect().top);
      lenis.scrollTo(target, { offset: top ? 0 : -80, duration: Math.min(1.6, 0.7 + distance / 4000), easing: easeInOut });
      if (!top) {
        // Keep keyboard focus with the section, as the browser's own jump would.
        if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1");
        target.focus({ preventScroll: true });
      }
      history.pushState(null, "", hash);
    };
    document.addEventListener("click", onClick);
    return () => {
      document.removeEventListener("click", onClick);
      lenis.destroy();
    };
  }, []);
}

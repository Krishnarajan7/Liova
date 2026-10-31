/**
 * A desktop wallpaper drawn as layered dunes at blue hour, in the spirit of macOS's landscape
 * wallpapers: a deep sky with the last light on the horizon, a moon, then hills from far (hazy,
 * pale) to near (deep). Drawn in SVG so it's sharp at any size and weighs almost nothing.
 */
export function Wallpaper({ className = "" }: { className?: string }) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      viewBox="0 0 1600 1000"
      preserveAspectRatio="xMidYMid slice"
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient id="wp-sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#141b3d" />
          <stop offset="0.45" stopColor="#3b4a8f" />
          <stop offset="0.72" stopColor="#8a8fc4" />
          <stop offset="0.9" stopColor="#e9b9a6" />
        </linearGradient>
        <radialGradient id="wp-moon" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#ffffff" stopOpacity="0.55" />
          <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
        </radialGradient>
        <linearGradient id="wp-h1" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#7d7fbf" />
          <stop offset="1" stopColor="#6567a8" />
        </linearGradient>
        <linearGradient id="wp-h2" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#555797" />
          <stop offset="1" stopColor="#40427f" />
        </linearGradient>
        <linearGradient id="wp-h3" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#373874" />
          <stop offset="1" stopColor="#272859" />
        </linearGradient>
        <linearGradient id="wp-h4" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#21224d" />
          <stop offset="1" stopColor="#161735" />
        </linearGradient>
        <linearGradient id="wp-h5" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#11122a" />
          <stop offset="1" stopColor="#08081a" />
        </linearGradient>
      </defs>
      <rect width="1600" height="1000" fill="url(#wp-sky)" />
      <g fill="#fff">
        <circle cx="210" cy="140" r="1.6" opacity="0.7" />
        <circle cx="420" cy="80" r="1.2" opacity="0.5" />
        <circle cx="640" cy="190" r="1.4" opacity="0.6" />
        <circle cx="900" cy="110" r="1.1" opacity="0.5" />
        <circle cx="1320" cy="70" r="1.5" opacity="0.7" />
        <circle cx="1480" cy="210" r="1.2" opacity="0.5" />
        <circle cx="1180" cy="240" r="1" opacity="0.4" />
      </g>
      <circle cx="1150" cy="300" r="170" fill="url(#wp-moon)" />
      <circle cx="1150" cy="300" r="46" fill="#f3f1ff" />
      <path d="M0 560 C 220 500 380 520 560 548 C 760 580 900 520 1100 505 C 1300 490 1460 530 1600 520 L1600 1000 L0 1000 Z" fill="url(#wp-h1)" />
      <path d="M0 640 C 180 600 360 590 540 630 C 720 672 860 640 1040 610 C 1240 578 1420 610 1600 640 L1600 1000 L0 1000 Z" fill="url(#wp-h2)" />
      <path d="M0 720 C 240 668 420 690 640 735 C 860 780 1040 700 1240 690 C 1400 682 1520 705 1600 720 L1600 1000 L0 1000 Z" fill="url(#wp-h3)" />
      <path d="M0 810 C 200 770 420 770 620 812 C 820 854 1000 800 1220 790 C 1380 784 1500 800 1600 815 L1600 1000 L0 1000 Z" fill="url(#wp-h4)" />
      <path d="M0 900 C 260 860 520 870 780 905 C 1040 940 1300 880 1600 892 L1600 1000 L0 1000 Z" fill="url(#wp-h5)" />
    </svg>
  );
}

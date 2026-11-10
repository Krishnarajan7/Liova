import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Icon({ size = 16, children, ...props }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
      {...props}
    >
      {children}
    </svg>
  );
}

export const Play = (p: IconProps) => (
  <Icon {...p}>
    <path d="M7 4.6v14.8c0 .9 1 1.4 1.7.9l11.2-7.4a1.1 1.1 0 0 0 0-1.8L8.7 3.7C8 3.2 7 3.7 7 4.6Z" />
  </Icon>
);
export const Pause = (p: IconProps) => (
  <Icon {...p}>
    <rect x="5.5" y="4" width="4.5" height="16" rx="1.4" />
    <rect x="14" y="4" width="4.5" height="16" rx="1.4" />
  </Icon>
);
export const Back = (p: IconProps) => (
  <Icon {...p}>
    <path d="M11.5 6.2v11.6c0 .8-.9 1.2-1.5.7L2.9 13a1.2 1.2 0 0 1 0-2L10 5.5c.6-.5 1.5-.1 1.5.7Zm10 0v11.6c0 .8-.9 1.2-1.5.7L12.9 13a1.2 1.2 0 0 1 0-2L20 5.5c.6-.5 1.5-.1 1.5.7Z" />
  </Icon>
);
export const Forward = (p: IconProps) => <Back {...p} style={{ transform: "scaleX(-1)", ...p.style }} />;
export const Bolt = (p: IconProps) => (
  <Icon {...p}>
    <path d="M13.6 2.3 4.8 13.1c-.4.5 0 1.2.6 1.2h5.4l-1.4 7.1c-.1.7.8 1.1 1.2.5l8.8-10.8c.4-.5 0-1.2-.6-1.2h-5.4l1.4-7.1c.1-.7-.8-1.1-1.2-.5Z" />
  </Icon>
);
export const Speaker = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 9.5v5c0 .6.4 1 1 1h3l4.3 3.6c.6.5 1.7.1 1.7-.8V5.7c0-.9-1.1-1.3-1.7-.8L7 8.5H4c-.6 0-1 .4-1 1Z" />
    <path
      d="M16 8.5a5 5 0 0 1 0 7M18.6 6a8.6 8.6 0 0 1 0 12"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
    />
  </Icon>
);
export const Sun = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="4.2" />
    <g stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
    </g>
  </Icon>
);
export const Hand = (p: IconProps) => (
  <Icon {...p}>
    <path d="M8.5 11V5a1.5 1.5 0 0 1 3 0v5.5V3.8a1.5 1.5 0 0 1 3 0v6.7V5a1.5 1.5 0 0 1 3 0v8.5l.6-1.6a1.6 1.6 0 0 1 3 1.1l-1.7 4.7A7 7 0 0 1 12.8 22h-.6A6.7 6.7 0 0 1 5.5 15.3V8a1.5 1.5 0 0 1 3 0v3Z" />
  </Icon>
);
export const Sparkle = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 2.5c.4 0 .7.3.8.6l1.3 4.2a4 4 0 0 0 2.6 2.6l4.2 1.3a.8.8 0 0 1 0 1.6l-4.2 1.3a4 4 0 0 0-2.6 2.6l-1.3 4.2a.8.8 0 0 1-1.6 0l-1.3-4.2a4 4 0 0 0-2.6-2.6l-4.2-1.3a.8.8 0 0 1 0-1.6l4.2-1.3a4 4 0 0 0 2.6-2.6l1.3-4.2c.1-.3.4-.6.8-.6Z" />
  </Icon>
);
export const Headphones = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="M4 15v-3a8 8 0 0 1 16 0v3"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
    />
    <rect x="3" y="13.5" width="5" height="8" rx="2.2" />
    <rect x="16" y="13.5" width="5" height="8" rx="2.2" />
  </Icon>
);
export const Download = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3a1.2 1.2 0 0 1 1.2 1.2v9.9l3.2-3.2a1.2 1.2 0 1 1 1.7 1.7l-5.2 5.2a1.2 1.2 0 0 1-1.8 0l-5.2-5.2a1.2 1.2 0 1 1 1.7-1.7l3.2 3.2V4.2A1.2 1.2 0 0 1 12 3Z" />
    <rect x="4" y="19" width="16" height="2.4" rx="1.2" />
  </Icon>
);
export const Rain = (p: IconProps) => (
  <Icon {...p}>
    <path d="M7 15.5a4.5 4.5 0 0 1-.4-9A6 6 0 0 1 18 7.6a4 4 0 0 1-.5 7.9H7Z" />
    <path
      d="M8 18.5 7 21M12.5 18.5l-1 2.5M17 18.5l-1 2.5"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
    />
  </Icon>
);
export const Timer = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="13.5" r="7.8" fill="none" stroke="currentColor" strokeWidth="2" />
    <path d="M12 9v4.5l3 2" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    <rect x="9.5" y="2" width="5" height="2.2" rx="1.1" />
  </Icon>
);
export const Calendar = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3" y="5" width="18" height="16" rx="3.5" fill="none" stroke="currentColor" strokeWidth="2" />
    <path d="M3 10h18" stroke="currentColor" strokeWidth="2" />
    <path d="M8 3v4M16 3v4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
  </Icon>
);
export const Tray = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="M3.5 13.5 6 5.8A2 2 0 0 1 7.9 4.5h8.2A2 2 0 0 1 18 5.8l2.5 7.7V18a2.5 2.5 0 0 1-2.5 2.5H6A2.5 2.5 0 0 1 3.5 18v-4.5Zm0 0h5l1 2h5l1-2h5"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinejoin="round"
    />
  </Icon>
);
export const Chip = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6" y="6" width="12" height="12" rx="2.5" fill="none" stroke="currentColor" strokeWidth="2" />
    <rect x="9.5" y="9.5" width="5" height="5" rx="1" />
    <path
      d="M9 2.5V5M15 2.5V5M9 19v2.5M15 19v2.5M2.5 9H5M2.5 15H5M19 9h2.5M19 15h2.5"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
    />
  </Icon>
);
export const Lock = (p: IconProps) => (
  <Icon {...p}>
    <rect x="4.5" y="10.5" width="15" height="11" rx="3" />
    <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" fill="none" stroke="currentColor" strokeWidth="2" />
  </Icon>
);
export const Eye = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinejoin="round"
    />
    <circle cx="12" cy="12" r="3" />
  </Icon>
);
export const Terminal = (p: IconProps) => (
  <Icon {...p}>
    <rect x="2.5" y="4" width="19" height="16" rx="3.5" fill="none" stroke="currentColor" strokeWidth="2" />
    <path d="m7 9.5 3 2.5-3 2.5M12.5 15h4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
  </Icon>
);
export const Leaf = (p: IconProps) => (
  <Icon {...p}>
    <path d="M20.5 3.5S9 3 5.5 9.5c-2 3.7-.6 7.3.6 8.8C8 15 11 12.5 15 11c-3.6 2.2-6.4 5.2-8 8.6 1.6 1.2 5.6 2 8.6-.6 4.8-4.2 4.9-15.5 4.9-15.5Z" />
  </Icon>
);
export const Github = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 2.2a10 10 0 0 0-3.2 19.5c.5.1.7-.2.7-.5v-1.7c-2.8.6-3.4-1.3-3.4-1.3-.4-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.3 1.1 2.9.8.1-.6.4-1.1.6-1.3-2.2-.3-4.6-1.1-4.6-5a3.9 3.9 0 0 1 1-2.7c-.1-.3-.4-1.3.1-2.7 0 0 .8-.3 2.8 1a9.6 9.6 0 0 1 5 0c1.9-1.3 2.8-1 2.8-1 .5 1.4.2 2.4.1 2.7a3.9 3.9 0 0 1 1 2.7c0 3.9-2.3 4.7-4.6 5 .4.3.7.9.7 1.9v2.7c0 .3.2.6.7.5A10 10 0 0 0 12 2.2Z" />
  </Icon>
);
export const Arrow = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="M5 12h13.5M13 6.5l5.5 5.5-5.5 5.5"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </Icon>
);
export const Plus = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
  </Icon>
);
export const Check = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="m5 12.5 4.5 4.5L19 7.5"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </Icon>
);
export const Wifi = (p: IconProps) => (
  <Icon {...p}>
    <path
      d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.6 16a5 5 0 0 1 6.8 0"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
    />
    <circle cx="12" cy="19.3" r="1.6" />
  </Icon>
);
export const Battery = (p: IconProps & { level?: number }) => {
  const { level = 0.8, ...rest } = p;
  return (
    <Icon {...rest} viewBox="0 0 28 14">
      <rect x="1" y="1" width="23" height="12" rx="3.5" fill="none" stroke="currentColor" strokeWidth="1.4" opacity=".55" />
      <rect x="3" y="3" width={19 * level} height="8" rx="2" />
      <path d="M25.5 5v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" opacity=".55" />
    </Icon>
  );
};
export const Home = (p: IconProps) => (
  <Icon {...p}>
    <path d="M11.3 2.7a1.1 1.1 0 0 1 1.4 0l8.6 7.4c.8.7.3 1.9-.7 1.9H19v7.4c0 1-.8 1.6-1.6 1.6h-3.2v-5.4a1.2 1.2 0 0 0-1.2-1.2h-2a1.2 1.2 0 0 0-1.2 1.2V21H6.6C5.8 21 5 20.4 5 19.4V12H3.4c-1 0-1.5-1.2-.7-1.9l8.6-7.4Z" />
  </Icon>
);
export const Gauge = (p: IconProps) => (
  <Icon {...p} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
    <circle cx="12" cy="12" r="9" />
    <path d="m12 13 4-4.5M7 12h.01M12 7h.01M17 12h.01" />
  </Icon>
);
export const Gear = (p: IconProps) => (
  <Icon {...p}>
    <path
      fillRule="evenodd"
      d="M10.3 2.4c.2-.8.9-1.4 1.7-1.4s1.5.6 1.7 1.4l.3 1.3c.7.2 1.3.5 1.9.9l1.2-.6c.7-.4 1.6-.2 2.1.4.6.6.7 1.4.4 2.1l-.6 1.2c.4.6.7 1.2.9 1.9l1.3.3c.8.2 1.4.9 1.4 1.7s-.6 1.5-1.4 1.7l-1.3.3c-.2.7-.5 1.3-.9 1.9l.6 1.2c.4.7.2 1.6-.4 2.1-.6.6-1.4.7-2.1.4l-1.2-.6c-.6.4-1.2.7-1.9.9l-.3 1.3c-.2.8-.9 1.4-1.7 1.4s-1.5-.6-1.7-1.4l-.3-1.3c-.7-.2-1.3-.5-1.9-.9l-1.2.6c-.7.4-1.6.2-2.1-.4-.6-.6-.7-1.4-.4-2.1l.6-1.2c-.4-.6-.7-1.2-.9-1.9l-1.3-.3C1.6 13.5 1 12.8 1 12s.6-1.5 1.4-1.7l1.3-.3c.2-.7.5-1.3.9-1.9l-.6-1.2c-.4-.7-.2-1.6.4-2.1.6-.6 1.4-.7 2.1-.4l1.2.6c.6-.4 1.2-.7 1.9-.9l.3-1.3ZM12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z"
    />
  </Icon>
);
export const Star = (p: IconProps) => (
  <Icon {...p}>
    <path d="M11.1 2.6a1 1 0 0 1 1.8 0l2.4 5.1 5.5.7a1 1 0 0 1 .6 1.7l-4.1 3.8 1.1 5.5a1 1 0 0 1-1.5 1.1L12 17.8l-4.9 2.7a1 1 0 0 1-1.5-1.1l1.1-5.5-4.1-3.8a1 1 0 0 1 .6-1.7l5.5-.7 2.4-5.1Z" />
  </Icon>
);
export const Flame = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12.6 2.2c.3-.3.8-.2.9.2.6 2 1.9 3.4 3.3 4.9 1.7 1.8 3.2 3.6 3.2 6.6A7.9 7.9 0 0 1 12 21.8a7.9 7.9 0 0 1-8-7.9c0-2.4 1-4.2 2.4-5.6.3-.3.9-.1.9.4 0 1.4.5 2.6 1.5 3.4.2.2.5 0 .5-.2-.4-3.6 1.1-7.4 3.3-9.7Zm-.4 10.4c-.2-.3-.7-.2-.8.1-.5 1.2-1.9 2-1.9 3.9a2.5 2.5 0 0 0 5 0c0-1.7-1.3-2.7-2.3-4Z" />
  </Icon>
);
export const Glass = (p: IconProps) => (
  <Icon {...p}>
    <path fillOpacity="0.35" d="M6 3h12a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3Z" />
    <path d="M6 3h12a3 3 0 0 1 3 3v2.5C17 6 11 6 3 9.5V6a3 3 0 0 1 3-3Z" />
    <path d="M8.5 13.2c2.2-.9 4.6-1.3 7-1.2.5 0 .5.7 0 .8-2.3.2-4.5.8-6.6 1.8-.6.3-1-.6-.4-1.4Z" />
  </Icon>
);

export const REPO = "https://github.com/Krishnarajan7/Liova";
/** Straight to the DMG of the newest release (the release workflow uploads it as Liova.dmg). */
export const GET_IT = `${REPO}/releases/latest/download/Liova.dmg`;
export const DOCS = `${REPO}/tree/main/docs`;
export const CHANGELOG = `${REPO}/blob/main/CHANGELOG.md`;
export const ISSUES = `${REPO}/issues/new/choose`;
export const DISCUSSIONS = `${REPO}/discussions`;
export const PRIVACY = `${REPO}#private-by-default`;
export const PERFORMANCE = `${REPO}/blob/main/docs/PERFORMANCE.md`;
export const PLUGIN_API = `${REPO}/blob/main/docs/PLUGIN-API.md`;
export const AGENT_ISLAND = `${REPO}/blob/main/docs/AGENT-ISLAND.md`;

/** Links that leave the site open in a new tab, so the page stays where you were. */
export const external = { target: "_blank", rel: "noopener noreferrer" } as const;

/** Liova's springs never overshoot: the notch is hardware, it shouldn't wobble. */
export const spring = { type: "spring", bounce: 0, duration: 0.55 } as const;

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { Still } from "./Still";
import "./index.css";

const still = new URLSearchParams(window.location.search).get("still");

createRoot(document.getElementById("root")!).render(<StrictMode>{still ? <Still name={still} /> : <App />}</StrictMode>);

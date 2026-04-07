import { createElement } from "react";
import { createRoot } from "react-dom/client";
import Playground from "./Playground";

const root = document.getElementById("playground-mount") || document.getElementById("playground-root");
if (root) {
  createRoot(root).render(createElement(Playground));
}

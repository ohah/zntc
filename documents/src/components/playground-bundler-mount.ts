import { createElement } from "react";
import { createRoot } from "react-dom/client";
import PlaygroundBundler from "./PlaygroundBundler";

const root =
  document.getElementById("playground-bundler-mount") ||
  document.getElementById("playground-mount");
if (root) {
  createRoot(root).render(createElement(PlaygroundBundler));
}

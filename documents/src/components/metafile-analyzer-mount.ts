import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { MetafileAnalyzer } from "./MetafileAnalyzer";

const el = document.getElementById("metafile-analyzer-mount");
if (el) {
  createRoot(el).render(createElement(MetafileAnalyzer));
}

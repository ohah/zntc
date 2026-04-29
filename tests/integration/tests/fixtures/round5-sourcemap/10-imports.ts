import { readFileSync as MARKER_READ } from "node:fs";
import * as MARKER_PATH from "node:path";

const MARKER_FILE = MARKER_PATH.join("/tmp", "x");
const MARKER_DATA = MARKER_READ(MARKER_FILE, "utf-8");
console.log(MARKER_DATA);

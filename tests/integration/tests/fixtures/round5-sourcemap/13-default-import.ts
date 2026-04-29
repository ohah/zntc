import MARKER_DEFAULT from "node:path";
import MARKER_OTHER, { sep as MARKER_SEP } from "node:path";

const MARKER_RES = MARKER_DEFAULT.join("/", "tmp");
console.log(MARKER_OTHER, MARKER_SEP, MARKER_RES);

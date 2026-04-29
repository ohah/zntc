function MARKER_FN(MARKER_FIRST: number, ...MARKER_REST: number[]): number {
  return MARKER_FIRST + MARKER_REST.length;
}
const MARKER_ARGS = [1, 2, 3];
const MARKER_RES = MARKER_FN(...MARKER_ARGS);
console.log(MARKER_RES);

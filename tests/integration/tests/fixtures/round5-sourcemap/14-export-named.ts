const MARKER_A = 1;
const MARKER_B = 2;
function MARKER_FN(MARKER_X: number): number {
  return MARKER_X * MARKER_A + MARKER_B;
}
export { MARKER_A, MARKER_B as MARKER_RENAMED, MARKER_FN };

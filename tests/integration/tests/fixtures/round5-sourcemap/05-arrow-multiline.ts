const MARKER_FN = (
  MARKER_X: number,
  MARKER_Y: string,
): number => {
  const MARKER_RES = MARKER_X + MARKER_Y.length;
  return MARKER_RES;
};
console.log(MARKER_FN(1, "ab"));

function* MARKER_GEN(MARKER_PARAM: number): Generator<number> {
  yield MARKER_PARAM;
  yield MARKER_PARAM * 2;
}

const MARKER_IT = MARKER_GEN(5);
for (const MARKER_VAL of MARKER_IT) {
  console.log(MARKER_VAL);
}

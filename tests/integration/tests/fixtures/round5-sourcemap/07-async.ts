async function MARKER_ASYNC(MARKER_PARAM: number): Promise<number> {
  const MARKER_AWAITED = await Promise.resolve(MARKER_PARAM);
  return MARKER_AWAITED * 2;
}
MARKER_ASYNC(5).then((MARKER_RES) => console.log(MARKER_RES));

class MARKER_CLS {
  MARKER_FIELD: number = 0;
  MARKER_METHOD(MARKER_PARAM: string): number {
    return MARKER_PARAM.length + this.MARKER_FIELD;
  }
}
const MARKER_INST = new MARKER_CLS();
console.log(MARKER_INST.MARKER_METHOD("hi"));

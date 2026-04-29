function MARKER_THROW(MARKER_MSG: string): never {
  throw new Error(MARKER_MSG);
}

try {
  MARKER_THROW("oops");
} catch (MARKER_ERR) {
  console.log(MARKER_ERR);
}

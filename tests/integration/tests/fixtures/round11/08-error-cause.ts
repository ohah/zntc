try {
  try {
    throw new Error("inner");
  } catch (e) {
    throw new Error("outer", { cause: e });
  }
} catch (e: any) {
  console.log(e.message, e.cause?.message);
}

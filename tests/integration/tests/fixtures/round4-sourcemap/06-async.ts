async function fetchData(): Promise<string> {
  await Promise.resolve();
  throw new Error("async-fail");
}
async function main() {
  try {
    await fetchData();
  } catch (e: any) {
    console.log(e.message, e.stack?.split("\n")[1]?.trim());
  }
}
main();

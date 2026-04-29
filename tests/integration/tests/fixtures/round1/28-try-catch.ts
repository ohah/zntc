function attempt(): string {
  try { throw new Error("boom"); }
  catch { return "caught-no-binding"; }
  finally { /* nothing */ }
}
console.log(attempt());
try { throw "raw"; } catch (e: any) { console.log(typeof e, e); }

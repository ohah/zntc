function attempt() {
  try { throw new Error("a"); }
  catch { throw new Error("b"); }
  finally { /* swallow? no, throws are independent */ }
}
try { attempt(); } catch (e: any) { console.log(e.message); }

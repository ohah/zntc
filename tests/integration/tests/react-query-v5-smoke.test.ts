import { afterEach, describe, expect, it } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { createFixture, hasPackage, linkNodeModules, runNode, runZts } from "./helpers";

const hasReactQuery = hasPackage("@tanstack/react-query");

describe.skipIf(!hasReactQuery)("React Query v5 smoke", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("@tanstack/react-query v5 bundles and executes QueryClient", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { QueryClient, QueryObserver } from "@tanstack/react-query";

        type Result = { ok: true; value: number };
        const client = new QueryClient();
        const observer = new QueryObserver<Result>(client, {
          queryKey: ["runtime-polyfills", "react-query-v5"],
          queryFn: async () => ({ ok: true, value: 42 }),
        });

        const unsubscribe = observer.subscribe(() => {});

        client
          .fetchQuery({
            queryKey: ["runtime-polyfills", "react-query-v5"],
            queryFn: async () => ({ ok: true, value: 42 }),
          })
          .then((result) => {
            console.log("react-query-v5", result?.ok === true, result.value);
            unsubscribe();
            client.clear();
          });
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, ["@tanstack/react-query", "@tanstack/query-core", "react"]);

    const outFile = join(fixture.dir, "out.cjs");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--format=cjs",
      "--platform=node",
    ]);
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    expect(js).toContain("QueryClient");
    expect(js).not.toContain("@tanstack/react-query");

    const run = await runNode(outFile);
    expect(run.stdout).toBe("react-query-v5 true 42");
  });
});

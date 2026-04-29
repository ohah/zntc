const config = {
  port: 3000,
  host: "localhost",
  debug: true,
} satisfies Record<string, string | number | boolean>;

const x = 5 as const;
const y = "literal" as const;
const arr = [1, "two", true] as const;
console.log(config.port, config.host, x, y, arr);

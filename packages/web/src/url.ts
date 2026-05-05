/** dev server / postcss / inject 공통 — base + rel path concat URL helper. */
export function joinUrl(base: string | undefined, rel: string): string {
  if (!base) return rel;
  return `${base}${rel}`;
}

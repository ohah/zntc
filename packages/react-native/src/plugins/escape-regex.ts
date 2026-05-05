// regex literal 로 사용할 string 의 special char escape — Metro asset path
// pattern / Babel preset detection / sourceExts 정규식 생성 등 plugin factory
// (asset/babel/codegen/require-context) 가 공용으로 사용.

const SPECIAL_CHARS_RE = /[.*+?^${}()|[\]\\]/g;

export function escapeRegex(s: string): string {
  return s.replace(SPECIAL_CHARS_RE, "\\$&");
}

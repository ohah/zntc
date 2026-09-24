// 모듈 최상위 블록과 export 된 같은 이름
export let shared = 'module';
{
  let shared = 'block';
  globalThis.__v = shared;
}
console.log(shared, globalThis.__v);

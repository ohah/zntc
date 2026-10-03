import { renamedLocal, renamedUpstream, upstreamDefault } from './barrel.mjs';
import { increment } from './upstream.mjs';

console.log(JSON.stringify([renamedLocal, renamedUpstream, upstreamDefault]));
increment();
console.log(JSON.stringify([renamedLocal, renamedUpstream, upstreamDefault]));

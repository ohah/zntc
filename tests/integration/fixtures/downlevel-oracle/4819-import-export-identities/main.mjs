import { exportedValue as importedValue } from './source.mjs';
const resultValue = importedValue + 1;
export { resultValue as outputValue };
console.log(resultValue);

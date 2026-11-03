export const initializations = [];
export function mark(value) {
  initializations.push('init');
  return value;
}
